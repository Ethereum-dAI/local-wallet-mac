# Confirmed API signatures (Kohaku `railgun` @ rev 877026e, spike 2026-07-13)

Build gate: `cargo build` PASS in ~1m07s (rustc 1.96, alloy unified to 1.8.3, shared with
railgun; transitive git forks `Robert-MacWha/circom-compat` + `ruint` resolved via lock).

## Types
- `railgun::chain_config::ChainConfig::sepolia()` → fields: `id: ChainId(=11155111)`,
  `railgun_smart_wallet: Address (0xeCFC…3fea)`, `unshield_fee_bps: u16 (=25)`,
  `relay_adapt_contract: Address`, `wrapped_base_token: Address (WETH 0xfFf9…6B14)`,
  `deployment_block: u64`, `subsquid_endpoint: String`, `poi_endpoint: String`,
  `privacy_paymaster: Option<Address>`, `railgun_fee_adapter: Option<Address>`.
- `railgun::caip::AssetId::Erc20(Address)` — ETH shields to WETH; balance keyed on `wrapped_base_token`.
- `railgun::provider::BalanceEntry { asset: AssetId, poi_status: Option<PoiStatus>, amount: u128 }`.
- `railgun::poi::types::PoiStatus = { Valid, ProofSubmitted, Missing, ShieldBlocked }`.
- `eip_1193_provider::tx_data::TxData { to: Address, data: Bytes, value: U256 }` (also re-exported via railgun); `impl From<TxData> for alloy TransactionRequest`.
- `railgun::transact::proved_transaction::ProvedTx { tx_data: TxData, proved_operations: Vec<ProvedOperation> }`.

## Construction / flow
- provider: `alloy::providers::ProviderBuilder::new().network::<Ethereum>().wallet(signer).connect(url).await?.erased()` → `DynProvider` (impls `IntoEip1193Provider`; no custom impl).
- syncer: `Arc::new(ChainedSyncer::new().then(SubsquidSyncer::new(&chain.subsquid_endpoint).with_latest_block(fork_block)).then(RpcSyncer::new(chain.clone(), provider.clone()).with_batch_size(1000)))`.
- `RailgunBuilder::new(chain, provider).with_utxo_syncer(syncer).build().await?` — DO NOT call `.with_poi()` on a fork.
- signer: `railgun::account::signer::PrivateKeySigner::new_evm(spending_key: SpendingKey, viewing_key: ViewingKey, chain_id: u64) -> Arc<PrivateKeySigner>`; `.address() -> RailgunAddress`.
- keys: `railgun::crypto::keys::{SpendingKey([u8;32]), ViewingKey([u8;32])}`; both impl `Distribution`/`rng.random()`. Deterministic derivation: `ChaCha20Rng::from_seed(entropy32)` then `rng.random()` for each. (`HexKey::from_hex` exists but `ByteKey` bound is `pub(crate)`.)
- shield: `railgun.shield().shield_native(addr, amount_u128).build(&mut rng)? -> Vec<TxData>` (no proof; RelayAdapt wrap→WETH).
- balance: `railgun.sync().await?` then `railgun.balance(addr).await -> Vec<BalanceEntry>`.
- unshield: `TransactionBuilder::new().unshield(signer.clone(), to: Address, AssetId::Erc20(weth), amount_u128)? ` → `railgun.build(builder, &mut rng).await? -> ProvedTx` (Groth16 proof; downloads artifacts first call). Submit `proved.tx_data.into()` from any EOA. Delivers WETH minus 25 bps.

## rand
- `rand = "0.9"`, `rand_chacha = "0.9"` (matches railgun's rand 0.9). `build<R: Rng>` accepts `&mut ChaCha20Rng`.

## Deviations from plan
- No `rust-toolchain.toml` pinning 1.85 (system stable is 1.96; pinning would force a rustup download). Crate builds on 1.96.
