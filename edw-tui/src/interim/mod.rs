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
pub mod swap;
pub mod tokens;

use std::{
    collections::BTreeMap,
    str::FromStr,
    sync::{Arc, Mutex},
    time::Duration,
};

use alloy_network::{EthereumWallet, TransactionBuilder};
use alloy_primitives::{Address, Bytes, I256, TxKind, U256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types_eth::TransactionRequest;
use alloy_signer_local::PrivateKeySigner;
use alloy_sol_types::{SolCall, sol};
use edw_core::{
    database::{
        Database, encrypted::EncryptedDatabase, file::FileDatabase, scoped::ScopedDatabaseExt,
    },
    mnemonic::{MnemonicRecord, db::MnemonicDb, resolve_mnemonic},
    network::{SupportedNetwork, db::NetworkDb},
    profile::simple::{ProfileRecord, db::SimpleProfileDb, resolve_profile},
};
use guards::{Amount, TokenRef, format_units, parse_units};
use reqwest::Url;
use serde_json::Value;

use crate::{
    addresses::AddressBook,
    edw::{self, EdwConfig, EdwResult},
    skills::{
        explain,
        plan::CheckedPlan,
        simulate::{self, Deltas},
    },
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
/// Prices an approval that can only be estimated once an earlier step is mined.
const APPROVE_GAS_CEILING: u64 = 100_000;

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
    /// Swap slippage tolerance in basis points (the app's default is 100, 1%; at most 5000).
    pub swap_slippage_bps: u64,
    /// Lets `mainnet` through, but only against an anvil fork on a loopback RPC
    /// (`EDW_TUI_MAINNET_FORK=1`); see [`fork_gate`].
    pub mainnet_fork: bool,
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
            swap_slippage_bps: std::env::var("EDW_TUI_SWAP_SLIPPAGE_BPS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(swap::DEFAULT_SLIPPAGE_BPS)
                .min(swap::MAX_SLIPPAGE_BPS),
            mainnet_fork: std::env::var("EDW_TUI_MAINNET_FORK").is_ok_and(|v| v == "1"),
        }
    }
}

/// What a skill script is told about where it runs.
#[derive(Clone, Debug)]
pub struct SkillContext {
    pub chain_id: u64,
    pub me: Address,
    pub network: String,
    pub rpc: Url,
}

/// One transaction of a prepared action.
struct Step {
    label: String,
    tx: TransactionRequest,
    /// Its gas can only be estimated once the steps before it are mined (a swap after its
    /// approval); everything else about it is fixed at the dry run.
    estimate_on_send: bool,
}

/// An action that passed its dry run: exactly these transactions are sent, in order, if the
/// user says yes. A transfer is one; a swap may add approvals before it.
pub struct Prepared {
    pub command: String,
    pub preview: String,
    steps: Vec<Step>,
    signer: PrivateKeySigner,
    rpc: Url,
}

impl Prepared {
    /// The first transaction (a transfer's only one).
    pub fn transaction(&self) -> &TransactionRequest {
        &self.steps[0].tx
    }

    pub fn transactions(&self) -> usize {
        self.steps.len()
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
    let error = error.to_string();
    if is_stale_fork(&error) {
        return format!(
            "the node cannot serve this chain state. This happens with an anvil fork whose upstream RPC has dropped the forked block (non-archive nodes keep recent state only); restart anvil, or fork from an archive RPC. ({error})"
        );
    }
    format!("the network endpoint returned an error: {error}")
}

fn is_stale_fork(error: &str) -> bool {
    [
        "historical state",
        "missing trie node",
        "state is not available",
    ]
    .iter()
    .any(|needle| error.contains(needle))
}

sol! {
    function getTransactionHash(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 _nonce) returns (bytes32);
}

/// The hash the Safe itself computes for a transaction's fields.
async fn bound_hash<P: Provider>(
    provider: &P,
    b: &crate::skills::plan::Binding,
) -> Result<alloy_primitives::B256, String> {
    let call = getTransactionHashCall {
        to: b.to,
        value: b.value,
        data: b.data.clone(),
        operation: b.operation,
        safeTxGas: b.safe_tx_gas,
        baseGas: b.base_gas,
        gasPrice: b.gas_price,
        gasToken: b.gas_token,
        refundReceiver: b.refund_receiver,
        _nonce: b.nonce,
    };
    let request = TransactionRequest::default()
        .to(b.safe)
        .input(call.abi_encode().into());
    let answer = provider.call(request).await.map_err(|e| {
        format!(
            "the Safe could not hash the transaction ({}), so nothing was sent",
            evm_reason(&e.to_string())
        )
    })?;
    getTransactionHashCall::abi_decode_returns(&answer)
        .map_err(|e| format!("the Safe's answer to getTransactionHash was unreadable ({e})"))
}

/// The EVM's own words from a failed simulation, e.g. `InvalidFEOpcode` or a revert reason.
fn evm_reason(error: &str) -> &str {
    error
        .rsplit_once("error code")
        .map_or(error, |(_, tail)| {
            tail.split_once(": ").map_or(tail, |(_, r)| r)
        })
        .trim()
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
            SupportedNetwork::Mainnet if !self.config.mainnet_fork => Err(
                "sending on mainnet is disabled while edw-tui's transfers are interim; unlock local or sepolia (an anvil mainnet fork works with EDW_TUI_MAINNET_FORK=1)".into(),
            ),
            SupportedNetwork::Sepolia if !self.config.allow_sepolia => Err(
                "interim sends on sepolia are off; set EDW_TUI_INTERIM_SEPOLIA=1 to allow them".into(),
            ),
            _ => Ok(network),
        }
    }

    pub fn set_profile(&self, selector: &str) {
        self.config.profile.set(selector);
    }

    pub fn profile(&self) -> String {
        self.config.profile.get()
    }

    /// The sending profile's account; `selector` overrides the harness's choice (for checks).
    /// The unlocked network, and edw's encrypted store for it, opened with the session password.
    async fn open_store(&self) -> Result<(SupportedNetwork, Arc<dyn Database>), String> {
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
        Ok((network, store))
    }

    async fn profiles(
        store: &Arc<dyn Database>,
    ) -> Result<(Vec<ProfileRecord>, Vec<MnemonicRecord>), String> {
        let profiles = store
            .clone()
            .scoped(b"profiles")
            .list_profiles()
            .await
            .map_err(|e| e.to_string())?;
        let mnemonics = store
            .clone()
            .scoped(b"mnemonics")
            .get_mnemonics()
            .await
            .map_err(|e| e.to_string())?;
        Ok((profiles, mnemonics))
    }

    /// A profile's signer: its first address, `m/44'/60'/<profile>'/0/0`.
    fn signer(
        mnemonics: &[MnemonicRecord],
        record: &ProfileRecord,
    ) -> Result<PrivateKeySigner, String> {
        resolve_mnemonic(mnemonics, record.mnemonic_index)
            .and_then(|m| m.mnemonic())
            .and_then(|m| m.standard_address_key(0, record.profile_index))
            .map(PrivateKeySigner::from_signing_key)
            .map_err(|e| format!("cannot derive the profile's key: {e}"))
    }

    fn label(record: &ProfileRecord) -> String {
        format!(
            "{} ({}/{})",
            record.display_name(),
            record.mnemonic_index,
            record.profile_index
        )
    }

    /// Every profile of the unlocked network with its address; the sending one is marked.
    pub async fn profile_addresses(&self) -> EdwResult {
        let command = format!("interim profile-addresses --from {}", self.profile());
        let listing = async {
            let (network, store) = self.open_store().await?;
            let (profiles, mnemonics) = Self::profiles(&store).await?;
            let sender = resolve_profile(&profiles, &self.profile()).ok().cloned();
            let mut lines = vec![format!("Profiles on {network}:")];
            for record in &profiles {
                let marker = if sender.as_ref() == Some(record) {
                    "  (sends transfers)"
                } else {
                    ""
                };
                lines.push(format!(
                    "  {}  {}{marker}",
                    Self::label(record),
                    Self::signer(&mnemonics, record)?.address()
                ));
            }
            Ok::<_, String>(lines.join("\n"))
        };
        match listing.await {
            Ok(output) => EdwResult {
                command,
                exit_code: 0,
                output,
            },
            Err(error) => failed(&command, error),
        }
    }

    async fn account(&self, selector: Option<&str>) -> Result<Account, String> {
        let selector = selector.map_or_else(|| self.profile(), str::to_owned);
        let (network, store) = self.open_store().await?;
        let (profiles, mnemonics) = Self::profiles(&store).await?;
        let record = resolve_profile(&profiles, &selector).map_err(|e| {
            format!(
                "the sending profile `{selector}` is not in this wallet ({e}); change it with /profile"
            )
        })?;
        let signer = Self::signer(&mnemonics, record)?;

        let rpc = match &self.config.rpc_url {
            Some(url) => url.clone(),
            None => endpoint(&store)
                .await
                .unwrap_or_else(|| network.default_config().http_rpc_url()),
        };
        Ok(Account {
            label: Self::label(record),
            chain_id: network.default_config().network_id.0,
            network,
            signer,
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
        // One unreadable token does not hide the others.
        for (symbol, address, decimals) in tokens {
            lines.push(match erc20_balance(&provider, address, owner).await {
                Ok(balance) => format!("  {} {symbol}", format_units(balance, decimals)),
                Err(error) if error.contains("cannot serve this chain state") => format!(
                    "  ? {symbol} (unavailable: the node dropped this state; restart the anvil fork)"
                ),
                Err(error) => format!("  ? {symbol} (unavailable: {error})"),
            });
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
            (Amount::All, Some(_)) if held.is_zero() => {
                return Err(format!(
                    "the profile holds no {symbol}, so there is nothing to send"
                ));
            }
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
        let gas = match provider.estimate_gas(tx.clone()).await {
            Ok(gas) => gas,
            Err(error) => {
                return Err(simulation_failed(
                    &provider,
                    &args.to,
                    token,
                    &symbol,
                    &error.to_string(),
                )
                .await);
            }
        };
        let max_cost = U256::from(gas) * max_fee;
        // "All" ETH was sized with a plain 21 000-gas fee. A contract recipient that accepts ETH
        // costs more gas, so the amount is what is left after the real fee.
        let value = match (&args.amount, token) {
            (Amount::All, None) if max_cost > simple_gas * max_fee => {
                let value = eth
                    .checked_sub(max_cost)
                    .filter(|v| !v.is_zero())
                    .ok_or_else(|| {
                        format!(
                            "the balance ({} ETH) does not cover the fee",
                            format_units(eth, 18)
                        )
                    })?;
                tx.set_value(value);
                value
            }
            _ => value,
        };
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
            steps: vec![Step {
                label: "transfer".into(),
                tx,
                estimate_on_send: false,
            }],
            signer: account.signer,
            rpc: account.rpc,
        })
    }

    /// Quotes, simulates and prices a Uniswap v3 exact-input swap without sending anything:
    /// any approval it needs, then the swap. `Err` means nothing will be asked or sent.
    pub async fn prepare_swap(&self, args: &Value) -> Result<Prepared, EdwResult> {
        let command = display_command("swap", args, &self.profile());
        self.try_prepare_swap(args, &command)
            .await
            .map_err(|error| failed(&command, error))
    }

    async fn try_prepare_swap(&self, args: &Value, command: &str) -> Result<Prepared, String> {
        let args = guards::swap_args(args)?;
        let account = self.account(None).await?;
        let chain = account.chain_id;
        let contracts = swap::contracts(chain).ok_or_else(|| {
            format!(
                "swaps use Uniswap v3, which edw-tui knows on Sepolia only (or an anvil fork of it); the unlocked network is chain {chain}"
            )
        })?;
        let wrapped =
            tokens::wrapped_native(chain).ok_or("no wrapped ETH is known on this chain")?;
        // ETH is quoted and routed as WETH, like the app does.
        let side = |token: &TokenRef| -> Result<(tokens::Token, bool), String> {
            match token {
                TokenRef::Native => Ok((tokens::Token { symbol: "ETH", ..wrapped }, true)),
                TokenRef::Symbol(symbol) => tokens::by_symbol(chain, symbol)
                    .map(|t| (t, false))
                    .ok_or_else(|| format!("{symbol} is not one of the wallet's known tokens on this chain")),
                TokenRef::Address(address) => tokens::by_address(chain, *address).map(|t| (t, false)).ok_or_else(|| {
                    format!("{address} is not one of the wallet's known tokens, and edw-tui only trades known tokens")
                }),
            }
        };
        let (token_in, in_is_native) = side(&args.from)?;
        let (token_out, out_is_native) = side(&args.to)?;
        if token_in.address == token_out.address {
            return Err("ETH and WETH are the same token here; wrapping is not a swap".into());
        }

        let provider = ProviderBuilder::new().connect_http(account.rpc.clone());
        check_chain(&provider, &account).await?;
        let owner = account.address();
        let amount_in = parse_units(&args.amount, token_in.decimals)?;
        let eth = provider.get_balance(owner).await.map_err(provider_error)?;
        let held = if in_is_native {
            eth
        } else {
            erc20_balance(&provider, token_in.address, owner).await?
        };
        if amount_in > held {
            return Err(format!(
                "not enough {}: the profile holds {}, the swap needs {}",
                token_in.symbol,
                format_units(held, token_in.decimals),
                args.amount
            ));
        }

        let slippage = self.config.swap_slippage_bps;
        let intermediates: Vec<Address> = tokens::swap_intermediates(chain)
            .iter()
            .map(|t| t.address)
            .filter(|a| *a != token_in.address && *a != token_out.address)
            .collect();
        let quote = swap::quote_best_route(
            &provider,
            contracts,
            token_in.address,
            token_out.address,
            amount_in,
            slippage,
            &intermediates,
        )
        .await?
        .ok_or_else(|| {
            format!(
                "no Uniswap v3 pool with liquidity connects {} and {} on chain {chain}, directly or through WETH, USDC, USDT or DAI",
                token_in.symbol, token_out.symbol
            )
        })?;

        // Approvals: exactly the amount in, reset to zero first if some other amount is set.
        let mut calls: Vec<(String, Address, U256, Bytes)> = Vec::new();
        if !in_is_native {
            let current =
                swap::allowance(&provider, token_in.address, owner, contracts.router).await?;
            if current < amount_in {
                if !current.is_zero() {
                    calls.push((
                        format!("reset the {} allowance to 0", token_in.symbol),
                        token_in.address,
                        U256::ZERO,
                        swap::approve_calldata(contracts.router, U256::ZERO),
                    ));
                }
                calls.push((
                    format!("approve {} {} for the router", args.amount, token_in.symbol),
                    token_in.address,
                    U256::ZERO,
                    swap::approve_calldata(contracts.router, amount_in),
                ));
            }
        }
        let needs_approval = !calls.is_empty();
        calls.push((
            "swap".into(),
            contracts.router,
            if in_is_native { amount_in } else { U256::ZERO },
            swap::router_calldata(&quote, amount_in, owner, contracts.router, out_is_native),
        ));

        let fees = provider
            .estimate_eip1559_fees()
            .await
            .map_err(provider_error)?;
        let nonce = provider
            .get_transaction_count(owner)
            .await
            .map_err(provider_error)?;
        let mut steps = Vec::new();
        let mut max_cost = U256::ZERO;
        for (index, (label, to, value, data)) in calls.into_iter().enumerate() {
            let is_swap = label == "swap";
            let tx = TransactionRequest::default()
                .with_from(owner)
                .with_to(to)
                .with_value(value)
                .with_input(data)
                .with_nonce(nonce + index as u64)
                .with_chain_id(chain)
                .with_max_fee_per_gas(fees.max_fee_per_gas)
                .with_max_priority_fee_per_gas(fees.max_priority_fee_per_gas);
            // Only the first step can be simulated now: every later one depends on the state the
            // earlier ones leave (a swap needs its approval; an approval after a reset writes a
            // zeroed slot, which costs far more gas than the non-zero one the dry run would see,
            // and USDT-style tokens refuse it outright). Later steps are estimated right before
            // they are sent; here they are priced with a generous ceiling.
            let (tx, gas, later) = if index > 0 {
                let gas = if is_swap {
                    (quote.gas_estimate.saturating_to::<u64>() + 100_000) * 3 / 2
                } else {
                    APPROVE_GAS_CEILING
                };
                (tx.with_gas_limit(gas), gas, true)
            } else {
                let gas = match provider.estimate_gas(tx.clone()).await {
                    Ok(gas) => gas,
                    Err(error) => {
                        let reason = evm_reason(&error.to_string()).to_owned();
                        return Err(format!(
                            "the {label} would fail in simulation ({reason}), so nothing was sent"
                        ));
                    }
                };
                (tx.with_gas_limit(gas), gas, false)
            };
            max_cost += U256::from(gas) * U256::from(fees.max_fee_per_gas);
            steps.push(Step {
                label,
                tx,
                estimate_on_send: later,
            });
        }
        let needed_eth = max_cost + if in_is_native { amount_in } else { U256::ZERO };
        if needed_eth > eth {
            return Err(format!(
                "not enough ETH for this swap and its fees: the profile holds {} ETH, it needs up to {} ETH",
                format_units(eth, 18),
                format_units(needed_eth, 18)
            ));
        }

        let symbol_of = |address: &Address| {
            tokens::by_address(chain, *address)
                .map_or_else(|| address.to_string(), |t| t.symbol.to_owned())
        };
        let mut route = symbol_of(&quote.route.tokens[0]);
        for (fee, token) in quote.route.fees.iter().zip(&quote.route.tokens[1..]) {
            route.push_str(&format!(
                " ─{}%→ {}",
                *fee as f64 / 10_000.0,
                symbol_of(token)
            ));
        }
        let out = |amount: U256| {
            format!(
                "{} {}",
                format_units(amount, token_out.decimals),
                token_out.symbol
            )
        };
        let mut preview = vec![
            format!("From     {}", account.describe()),
            format!(
                "Swap     {} {} → about {}",
                args.amount,
                token_in.symbol,
                out(quote.amount_out)
            ),
            format!(
                "At least {}  ({}% slippage)",
                out(quote.amount_out_minimum),
                slippage as f64 / 100.0
            ),
            format!(
                "Route    {route}  (Uniswap v3, router {})",
                contracts.router
            ),
        ];
        if steps.len() > 1 {
            let list = steps
                .iter()
                .enumerate()
                .map(|(i, s)| format!("{}. {}", i + 1, s.label))
                .collect::<Vec<_>>()
                .join("  ");
            preview.push(format!("Sends    {} transactions: {list}", steps.len()));
        }
        preview.push(format!(
            "Max fee  {} ETH{}",
            format_units(max_cost, 18),
            if needs_approval {
                " (steps after the first are estimated as they are sent)"
            } else {
                ""
            }
        ));
        preview.push("Signed by edw-tui's interim executor (edw-core), not edw's CLI".into());

        Ok(Prepared {
            command: command.to_owned(),
            preview: preview.join("\n"),
            steps,
            signer: account.signer,
            rpc: account.rpc,
        })
    }

    /// Where skill scripts run against: the unlocked chain, the sending profile's address and
    /// the RPC, after the same chain (and mainnet-fork) checks every send gets.
    pub async fn skill_context(&self) -> Result<SkillContext, String> {
        let account = self.account(None).await?;
        let provider = ProviderBuilder::new().connect_http(account.rpc.clone());
        check_chain(&provider, &account).await?;
        Ok(SkillContext {
            chain_id: account.chain_id,
            me: account.address(),
            network: account.network.to_string(),
            rpc: account.rpc,
        })
    }

    /// A checked skill plan as a reviewed dry run, like a transfer's: the whole plan simulated
    /// in one block, the review written from the plan's labels and the simulation, and only
    /// these transactions sent (by [`Interim::broadcast`]) after a yes. `header` goes on top of
    /// the review; `names` labels tokens in the simulated changes.
    pub async fn prepare_plan(
        &self,
        command: String,
        header: Vec<String>,
        plan: CheckedPlan,
        names: &BTreeMap<Address, (String, u8)>,
        checked_for: &SkillContext,
    ) -> Result<Prepared, String> {
        let account = self.account(None).await?;
        // The plan's `$self` and contract ids were resolved for `checked_for`; if the session's
        // network or sender changed while the script ran, they would mean something else.
        if account.chain_id != checked_for.chain_id || account.address() != checked_for.me {
            return Err(format!(
                "the wallet changed while the skill ran (it was {} on chain {}, now {} on chain {}); nothing was sent",
                checked_for.me,
                checked_for.chain_id,
                account.address(),
                account.chain_id
            ));
        }
        let provider = ProviderBuilder::new().connect_http(account.rpc.clone());
        check_chain(&provider, &account).await?;
        let me = account.address();
        let eth = provider.get_balance(me).await.map_err(provider_error)?;
        if plan.total_value > eth {
            return Err(format!(
                "not enough ETH: the profile holds {} ETH, the plan sends {} ETH",
                format_units(eth, 18),
                format_units(plan.total_value, 18)
            ));
        }
        for step in &plan.steps {
            if let Some((token, amount)) = step.approval {
                let held = erc20_balance(&provider, token, me).await?;
                if amount > held {
                    let (symbol, decimals) = names
                        .get(&token)
                        .cloned()
                        .unwrap_or_else(|| (token.to_string(), 0));
                    return Err(format!(
                        "not enough {symbol}: the profile holds {}, the plan approves {}",
                        format_units(held, decimals),
                        format_units(amount, decimals)
                    ));
                }
            }
        }

        let results = simulate::simulate(&account.rpc, me, &plan.steps).await?;
        for (index, (result, step)) in results.iter().zip(&plan.steps).enumerate() {
            if !result.ok {
                let reason = result.error.as_deref().unwrap_or("reverted");
                return Err(format!(
                    "step {} ({}) would fail in simulation ({}), so nothing was sent",
                    index + 1,
                    step.label,
                    evm_reason(reason)
                ));
            }
        }
        let deltas = simulate::deltas(me, &results);

        let fees = provider
            .estimate_eip1559_fees()
            .await
            .map_err(provider_error)?;
        let nonce = provider
            .get_transaction_count(me)
            .await
            .map_err(provider_error)?;
        let mut steps = Vec::new();
        let mut max_cost = U256::ZERO;
        for (index, (step, result)) in plan.steps.iter().zip(&results).enumerate() {
            let mut gas = result.gas_used * 13 / 10 + 25_000;
            let tx = TransactionRequest::default()
                .with_from(me)
                .with_to(step.to)
                .with_value(step.value)
                .with_input(step.data.clone())
                .with_nonce(nonce + index as u64)
                .with_chain_id(account.chain_id);
            if index == 0 {
                // What a call used is not what it needs: a Safe will not even start an inner call
                // unless it was given its `safeTxGas` up front. The node's own estimate searches for
                // the least gas that does not revert; when it cannot answer, nothing is sent rather
                // than guessing low. (Later steps are re-estimated when sent.)
                let estimated = provider.estimate_gas(tx.clone()).await.map_err(|error| {
                    format!(
                        "step 1 ({}): the node could not estimate its gas ({}), so nothing was sent",
                        step.label,
                        evm_reason(&error.to_string())
                    )
                })?;
                gas = gas.max(estimated * 12 / 10);
                // The review is only honest if the call also works with the gas it will be sent with.
                if let Err(error) = provider.call(tx.clone().with_gas_limit(gas)).await {
                    return Err(format!(
                        "step 1 ({}) would fail with the gas it would be sent with ({}), so nothing was sent",
                        step.label,
                        evm_reason(&error.to_string())
                    ));
                }
            }
            max_cost += U256::from(gas) * U256::from(fees.max_fee_per_gas);
            steps.push(Step {
                label: step.label.clone(),
                tx: tx
                    .with_gas_limit(gas)
                    .with_max_fee_per_gas(fees.max_fee_per_gas)
                    .with_max_priority_fee_per_gas(fees.max_priority_fee_per_gas),
                // Re-checked right before sending, on the state the earlier steps left.
                estimate_on_send: index > 0,
            });
        }
        let needed = plan.total_value + max_cost;
        if needed > eth {
            return Err(format!(
                "not enough ETH for this plan and its fees: the profile holds {} ETH, it needs up to {} ETH",
                format_units(eth, 18),
                format_units(needed, 18)
            ));
        }

        // An approval of a Safe transaction hash names the transaction behind it. The Safe itself
        // says whether those fields produce that hash; only then does the review explain them.
        let mut explained: Vec<Vec<String>> = Vec::new();
        for step in &plan.steps {
            let mut lines = step.details.clone();
            if let Some(binding) = &step.binding {
                let computed = bound_hash(&provider, binding).await?;
                if computed != binding.hash {
                    return Err(format!(
                        "the transaction this step approves does not hash to {} on the Safe (it computes {computed}), so nothing was sent",
                        binding.hash
                    ));
                }
                lines.push(format!(
                    "the Safe confirms this hash is for nonce {}:",
                    binding.nonce
                ));
                lines.extend(
                    explain::describe(
                        binding.safe,
                        binding.to,
                        binding.value,
                        &binding.data,
                        binding.operation,
                    )
                    .into_iter()
                    .map(|l| format!("does: {l}")),
                );
            }
            explained.push(lines);
        }
        let mut preview = header;
        preview.push(format!("From     {}", account.describe()));
        for (index, step) in plan.steps.iter().enumerate() {
            preview.push(format!("Step {}   {}", index + 1, step.label));
            for detail in &explained[index] {
                preview.push(format!("           {detail}"));
            }
        }
        for note in &plan.notes {
            preview.push(format!("Skill says (not checked): {note}"));
        }
        preview.push(format!(
            "Changes  {} (simulated)",
            describe_deltas(&deltas, names)
        ));
        preview.push(format!("Max fee  {} ETH", format_units(max_cost, 18)));
        preview.push("Signed by edw-tui's interim executor (edw-core), not edw's CLI".into());
        Ok(Prepared {
            command,
            preview: preview.join("\n"),
            steps,
            signer: account.signer,
            rpc: account.rpc,
        })
    }

    /// Sends the prepared transactions in order, each after the previous one succeeded, and
    /// stops at the first failure.
    pub async fn broadcast(&self, prepared: Prepared) -> EdwResult {
        let command = prepared.command.clone();
        let provider = ProviderBuilder::new()
            .wallet(EthereumWallet::from(prepared.signer))
            .connect_http(prepared.rpc);
        let total = prepared.steps.len();
        let mut done: Vec<String> = Vec::new();
        let report = |done: &[String], last: String| {
            let mut lines = done.to_vec();
            lines.push(last);
            lines.join("\n")
        };
        for step in prepared.steps {
            let mut tx = step.tx;
            if step.estimate_on_send {
                match provider.estimate_gas(tx.clone()).await {
                    Ok(gas) => tx.set_gas_limit(gas),
                    Err(error) => {
                        let reason = evm_reason(&error.to_string()).to_owned();
                        return failed(
                            &command,
                            report(
                                &done,
                                format!(
                                    "{}: the simulation now fails ({reason}), so it was not sent",
                                    step.label
                                ),
                            ),
                        );
                    }
                }
            }
            match send_and_wait(&provider, tx).await {
                Ok(line) if total == 1 => {
                    return EdwResult {
                        command,
                        exit_code: 0,
                        output: format!("Sent. {line}"),
                    };
                }
                Ok(line) => done.push(format!("{}: {line}", step.label)),
                Err(error) => {
                    let nothing = if done.is_empty() && error.starts_with("sending failed") {
                        ", nothing was sent"
                    } else {
                        ""
                    };
                    let line = if total == 1 {
                        format!("{error}{nothing}")
                    } else {
                        format!("{}: {error}{nothing}", step.label)
                    };
                    return failed(&command, report(&done, line));
                }
            }
        }
        EdwResult {
            command,
            exit_code: 0,
            output: format!(
                "Sent {total} transactions, all succeeded:\n{}",
                done.join("\n")
            ),
        }
    }
}

/// Sends one transaction and waits for its receipt: `Ok` with a line describing the included,
/// successful transaction, `Err` otherwise.
async fn send_and_wait(provider: &impl Provider, tx: TransactionRequest) -> Result<String, String> {
    let pending = provider
        .send_transaction(tx)
        .await
        .map_err(|error| format!("sending failed: {error}"))?;
    let hash = *pending.tx_hash();
    let receipt = tokio::time::timeout(RECEIPT_TIMEOUT, pending.get_receipt())
        .await
        .map_err(|_| {
            format!("sent as {hash}, but no receipt arrived within {RECEIPT_TIMEOUT:?}; check it before retrying")
        })?
        .map_err(|error| format!("sent as {hash}, but the receipt could not be read: {error}"))?;
    let block = receipt.block_number.map_or("?".into(), |b| b.to_string());
    if receipt.status() {
        Ok(format!(
            "Transaction {hash} was included in block {block} and succeeded (gas used {}).",
            receipt.gas_used
        ))
    } else {
        Err(format!(
            "transaction {hash} was included in block {block} but reverted; no funds moved"
        ))
    }
}

/// Why a simulated transfer failed, said in terms of the recipient or the token rather than
/// the RPC error, and always saying that nothing was sent.
async fn simulation_failed(
    provider: &impl Provider,
    to: &Address,
    token: Option<Address>,
    symbol: &str,
    error: &str,
) -> String {
    if is_stale_fork(error) {
        return provider_error(error);
    }
    let reason = evm_reason(error);
    match token {
        Some(address) => format!(
            "the {symbol} contract ({address}) rejected this transfer in simulation ({reason}), so nothing was sent; check the amount and the recipient"
        ),
        None if provider
            .get_code_at(*to)
            .await
            .is_ok_and(|code| !code.is_empty()) =>
        {
            format!(
                "{to} has contract code, and it rejected the ETH in simulation ({reason}), so nothing was sent. Sending to it would fail; double-check the address."
            )
        }
        None => format!("the transfer failed in simulation ({reason}), so nothing was sent"),
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
    if account.network == SupportedNetwork::Mainnet {
        // Only reachable with EDW_TUI_MAINNET_FORK=1 (see `unlocked_network`).
        let info: Value = provider
            .raw_request("anvil_nodeInfo".into(), ())
            .await
            .unwrap_or(Value::Null);
        let fork_url = info.pointer("/forkConfig/forkUrl").and_then(Value::as_str);
        fork_gate(account.network, true, &account.rpc, fork_url)?;
    }
    Ok(())
}

/// Mainnet only on an anvil fork: the flag set, a loopback RPC, and a node that reports a fork
/// URL. Anything else that claims to be mainnet is refused before a key is used.
fn fork_gate(
    network: SupportedNetwork,
    mainnet_fork: bool,
    rpc: &Url,
    fork_url: Option<&str>,
) -> Result<(), String> {
    if network != SupportedNetwork::Mainnet {
        return Ok(());
    }
    if !mainnet_fork {
        return Err("sending on mainnet is disabled; an anvil mainnet fork works with EDW_TUI_MAINNET_FORK=1".into());
    }
    let host = rpc
        .host_str()
        .unwrap_or_default()
        .trim_start_matches('[')
        .trim_end_matches(']');
    let loopback = host == "localhost"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback());
    if !loopback {
        return Err(format!(
            "mainnet-fork mode needs a loopback RPC (EDW_TUI_RPC_URL=http://127.0.0.1:…), not {rpc}"
        ));
    }
    if fork_url.is_none_or(str::is_empty) {
        return Err(format!(
            "the node at {rpc} is not an anvil fork, so mainnet-fork mode will not use it"
        ));
    }
    Ok(())
}

/// Signed amounts, ETH first, named where the skill or the wallet knows the token.
fn describe_deltas(deltas: &Deltas, names: &BTreeMap<Address, (String, u8)>) -> String {
    let signed = |value: I256, decimals: u8, unit: &str| {
        let sign = if value.is_negative() { '−' } else { '+' };
        format!(
            "{sign}{} {unit}",
            format_units(value.unsigned_abs(), decimals)
        )
    };
    let mut parts = Vec::new();
    if !deltas.eth.is_zero() {
        parts.push(signed(deltas.eth, 18, "ETH"));
    }
    for (token, amount) in &deltas.erc20 {
        parts.push(match names.get(token) {
            Some((symbol, decimals)) => signed(*amount, *decimals, symbol),
            None => {
                let sign = if amount.is_negative() { '−' } else { '+' };
                format!("{sign}{} units of {token}", amount.unsigned_abs())
            }
        });
    }
    let name = |token: &Address| {
        names
            .get(token)
            .map_or_else(|| token.to_string(), |(s, _)| s.clone())
    };
    parts.extend(
        deltas
            .nfts_in
            .iter()
            .map(|(token, id)| format!("+NFT #{id} of {}", name(token))),
    );
    parts.extend(
        deltas
            .nfts_out
            .iter()
            .map(|(token, id)| format!("−NFT #{id} of {}", name(token))),
    );
    if parts.is_empty() {
        "none".into()
    } else {
        parts.join(", ")
    }
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
    fn mainnet_is_allowed_only_on_a_local_anvil_fork_with_the_flag() {
        let local: Url = "http://127.0.0.1:8546".parse().unwrap();
        let remote: Url = "https://eth.llamarpc.com".parse().unwrap();
        let fork = Some("https://archive.example");
        let mainnet = SupportedNetwork::Mainnet;
        assert!(
            fork_gate(mainnet, false, &local, fork)
                .unwrap_err()
                .contains("EDW_TUI_MAINNET_FORK")
        );
        assert!(
            fork_gate(mainnet, true, &remote, fork)
                .unwrap_err()
                .contains("loopback")
        );
        assert!(
            fork_gate(mainnet, true, &local, None)
                .unwrap_err()
                .contains("fork")
        );
        assert!(
            fork_gate(
                mainnet,
                true,
                &"http://localhost:8546".parse().unwrap(),
                fork
            )
            .is_ok()
        );
        assert!(fork_gate(mainnet, true, &local, fork).is_ok());
        // Other networks are not this gate's business.
        assert!(fork_gate(SupportedNetwork::Sepolia, false, &remote, None).is_ok());
        assert!(fork_gate(SupportedNetwork::Local, false, &local, None).is_ok());
    }

    #[test]
    fn deltas_read_as_signed_amounts_with_names() {
        let usdc = Address::repeat_byte(1);
        let mut d = crate::skills::simulate::Deltas {
            eth: I256::try_from(-500_000_000_000_000_000i128).unwrap(),
            ..Default::default()
        };
        d.erc20.insert(usdc, I256::try_from(100_000_000).unwrap());
        d.erc20
            .insert(Address::repeat_byte(2), I256::try_from(-7).unwrap());
        let names = BTreeMap::from([(usdc, ("USDC".to_owned(), 6u8))]);
        assert_eq!(
            describe_deltas(&d, &names),
            format!(
                "−0.5 ETH, +100 USDC, −7 units of {}",
                Address::repeat_byte(2)
            )
        );
        assert_eq!(describe_deltas(&Default::default(), &names), "none");
    }

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
    fn explains_rpc_failures_in_plain_words() {
        assert_eq!(
            evm_reason(
                "server returned an error response: error code -32603: EVM error InvalidFEOpcode"
            ),
            "EVM error InvalidFEOpcode"
        );
        let stale = "error code -32000: historical state f5599e0b is not available";
        assert!(is_stale_fork(stale));
        assert!(provider_error(stale).contains("restart anvil"));
        assert!(!is_stale_fork(
            "error code -32603: EVM error InvalidFEOpcode"
        ));
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
