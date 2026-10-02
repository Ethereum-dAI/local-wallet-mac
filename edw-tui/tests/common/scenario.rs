//! A feature scenario through the real terminal, as short to write as the steps a person would
//! take: start a chain, seed a known wallet, drive `edw-tui` in a PTY, save screenshots, and
//! optionally record an MP4 (see `.claude/skills/feature-video/SKILL.md`).
//!
//! The wallet uses Foundry's public test mnemonic, so addresses are the same on every run.
//! Never use it for anything but throwaway chains.

use std::{path::PathBuf, sync::Arc};

use alloy_node_bindings::{Anvil, AnvilInstance};
use alloy_primitives::{Address, U256};
use alloy_provider::{Provider, ProviderBuilder};
use edw_core::database::{Database, encrypted::EncryptedDatabase, file::FileDatabase};
use edw_tui::{
    edw::{self, Pin},
    interim::Interim,
};

use super::{TempWallet, edw_binary, pty::Tui};

pub const TEST_MNEMONIC: &str = "test test test test test test test test test test test junk";
pub const ETHER: u128 = 1_000_000_000_000_000_000;
const ROWS: u16 = 50;
const COLS: u16 = 240;

/// Which chain the scenario runs on.
pub enum Chain {
    /// A fresh anvil; edw's `local` network.
    Local,
    /// An anvil fork of Sepolia (`EDW_TUI_SEPOLIA_RPC`, default a no-tracking public RPC);
    /// edw's `sepolia` network. Needs the network.
    SepoliaFork,
}

pub struct Scenario {
    pub tui: Tui,
    pub wallet: TempWallet,
    pub rpc: String,
    pub network: &'static str,
    _chain: AnvilInstance,
}

impl Scenario {
    /// Starts the chain, seeds the wallet for its network, and launches `edw-tui` with the
    /// scripted model. `None` (with a message) when edw or anvil is missing, or edw is not the
    /// pinned revision. Recording starts when `EDW_TUI_E2E_RECORD` is set.
    pub async fn start(name: &str, chain: Chain) -> Option<Self> {
        let binary = edw_binary().or_else(|| {
            eprintln!("skipping: edw is not installed");
            None
        })?;
        if edw::check_pin(&binary) != Pin::Matches {
            eprintln!("skipping: the installed edw is not the pinned revision");
            return None;
        }
        let (anvil, network) = match chain {
            Chain::Local => (Anvil::new(), "local"),
            Chain::SepoliaFork => (
                Anvil::new().fork(
                    std::env::var("EDW_TUI_SEPOLIA_RPC")
                        .unwrap_or_else(|_| "https://ethereum-sepolia-rpc.publicnode.com".into()),
                ),
                "sepolia",
            ),
        };
        let chain = match anvil.try_spawn() {
            Ok(chain) => chain,
            Err(error) => {
                eprintln!("skipping: cannot start anvil ({error})");
                return None;
            }
        };
        let rpc = chain.endpoint();
        let wallet = TempWallet::new(binary.clone(), name);
        seed_wallet(&wallet.config, network).await;

        let config = &wallet.config;
        let mut tui = Tui::spawn(
            &PathBuf::from(env!("CARGO_BIN_EXE_edw-tui")),
            &[
                ("EDW_TUI_MODEL", "scripted".into()),
                ("EDW_BIN", binary.display().to_string()),
                ("EDW_DATA_DIR", config.data_dir.display().to_string()),
                ("EDW_RUNTIME_DIR", config.runtime_dir.display().to_string()),
                ("EDW_DECRYPTION_PASSWORD", config.password.clone()),
                ("EDW_TUI_RPC_URL", rpc.clone()),
                ("EDW_TUI_INTERIM_SEPOLIA", "1".into()),
                // These scenarios are about transfers and swaps; skills have their own e2e test.
                ("EDW_TUI_SKILLS", "off".into()),
            ],
            ROWS,
            COLS,
        );
        if recording() {
            tui.start_recording();
        }
        tui.wait_for("Ask in plain language");
        tui.linger(800);
        Some(Self {
            tui,
            wallet,
            rpc,
            network,
            _chain: chain,
        })
    }

    /// Types a request, answers its confirmation with `y`, and waits for `done` on screen and
    /// for the agent to finish.
    pub fn confirmed(&mut self, request: &str, done: &str) {
        self.tui.submit(request);
        self.tui
            .wait_for_within("a confirmation", 240, |s| s.contains("[y] "));
        self.tui.linger(2500); // time to read the review in a recording
        self.tui.answer(b"y");
        self.tui.wait_for_within(done, 240, |s| s.contains(done));
        self.idle();
    }

    /// Types a request that needs no confirmation and waits for `done` on screen.
    pub fn ask(&mut self, request: &str, done: &str) {
        self.tui.submit(request);
        self.tui.wait_for_within(done, 240, |s| s.contains(done));
        self.idle();
        self.tui.linger(1200);
    }

    pub fn idle(&self) {
        self.tui
            .wait_for_within("the agent to finish", 240, |s| !s.contains("thinking…"));
    }

    /// The address of a profile (`0/0`, `alice`, …) in the unlocked wallet.
    pub async fn address(&self, profile: &str) -> Address {
        Interim::new(self.wallet.interim(Some(self.rpc.clone()), true))
            .address(Some(profile))
            .await
            .unwrap()
    }

    /// Gives `who` ETH on the chain, and clears any contract code it has there: on a fork, the
    /// test mnemonic's accounts carry EIP-7702 delegations set by sweeper bots.
    pub async fn fund(&self, who: Address, wei: U256) {
        let provider = ProviderBuilder::new().connect_http(self.rpc.parse().unwrap());
        let _: () = provider
            .raw_request("anvil_setCode".into(), (who, "0x"))
            .await
            .unwrap();
        let _: () = provider
            .raw_request("anvil_setBalance".into(), (who, wei))
            .await
            .unwrap();
    }

    pub async fn eth(&self, who: Address) -> U256 {
        ProviderBuilder::new()
            .connect_http(self.rpc.parse().unwrap())
            .get_balance(who)
            .await
            .unwrap()
    }

    /// Saves the screen as `<name>.svg` and `<name>.txt` in `target/e2e-screenshots/`.
    pub fn screenshot(&self, name: &str) {
        let dir = screenshots_dir();
        std::fs::write(dir.join(format!("{name}.svg")), self.tui.screenshot_svg()).unwrap();
        std::fs::write(dir.join(format!("{name}.txt")), self.tui.screen()).unwrap();
    }

    /// Stops recording (if on) and writes `target/e2e-screenshots/<name>.mp4`; returns its path.
    pub fn finish(&mut self, name: &str) -> Option<PathBuf> {
        self.tui.linger(1500);
        let video = self.tui.finish_recording(&screenshots_dir(), name);
        if let Some(video) = &video {
            eprintln!("recorded {}", video.display());
        }
        video
    }
}

pub fn recording() -> bool {
    std::env::var("EDW_TUI_E2E_RECORD").is_ok_and(|v| !v.is_empty() && v != "0")
}

pub fn screenshots_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/e2e-screenshots");
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Creates `network`'s store as edw's first unlock does (encrypted with the password,
/// mnemonic 0, profile 0), but with the known test mnemonic instead of a random one.
pub async fn seed_wallet(config: &edw::EdwConfig, network: &str) {
    let dir = config.data_dir.join(network);
    std::fs::create_dir_all(&dir).unwrap();
    let backend: Arc<dyn Database> = Arc::new(FileDatabase::open(&dir).unwrap());
    let store: Arc<dyn Database> = Arc::new(
        EncryptedDatabase::create(backend, config.password.as_bytes())
            .await
            .unwrap(),
    );
    let record = edw_core::mnemonic::add_mnemonic(store.clone(), TEST_MNEMONIC.to_owned().into())
        .await
        .unwrap();
    edw_core::profile::simple::bootstrap_profile(store, record.index, 0, None)
        .await
        .unwrap();
}
