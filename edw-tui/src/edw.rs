//! Deterministic mapping from a tool call onto the `edw` CLI, and running it.
//!
//! The model only picks a tool name and JSON arguments. This module validates them, builds an
//! argv list (never a shell string), runs `edw` with no stdin so it can never block on a prompt,
//! and redacts recovery phrases before output reaches the model or the screen.
//!
//! Only commands `edw` implements today are exposed. `profile import` is left out on purpose:
//! it reads a recovery phrase from stdin, and a phrase must never pass through a chat.

use std::{
    path::{Path, PathBuf},
    process::Stdio,
    sync::LazyLock,
    time::Duration,
};

use regex::Regex;
use serde_json::{Map, Value, json};
use tokio::process::Command;

pub const NETWORKS: [&str; 3] = ["mainnet", "sepolia", "local"];
const MAX_TEXT: usize = 64;

pub struct ToolSpec {
    pub name: &'static str,
    pub description: &'static str,
    /// Changes wallet state, so the user confirms it before it runs.
    pub mutating: bool,
    pub parameters: fn() -> Value,
}

fn no_params() -> Value {
    json!({"type": "object", "properties": {}})
}

pub const TOOLS: [ToolSpec; 8] = [
    ToolSpec {
        name: "wallet_status",
        description: "Show the wallet configuration: data directory, which network is unlocked (or locked), and the RPC source.",
        mutating: false,
        parameters: no_params,
    },
    ToolSpec {
        name: "unlock",
        description: "Unlock one network; every other network is locked. The first unlock of a network creates its encrypted store with mnemonic 0 and profile 0.",
        mutating: true,
        parameters: || {
            json!({"type": "object", "properties": {
                "network": {"type": "string", "enum": NETWORKS, "description": "Defaults to sepolia."}
            }})
        },
    },
    ToolSpec {
        name: "lock",
        description: "Lock the wallet.",
        mutating: false,
        parameters: no_params,
    },
    ToolSpec {
        name: "list_profiles",
        description: "List the wallet's profiles, grouped by mnemonic.",
        mutating: false,
        parameters: no_params,
    },
    ToolSpec {
        name: "new_mnemonic",
        description: "Generate a brand-new mnemonic (a separate seed) with one profile on it. Only use this when the user explicitly asks for a new seed or mnemonic; to add profiles to the current wallet use add_profile.",
        mutating: true,
        parameters: || {
            json!({"type": "object", "properties": {
                "name": {"type": "string", "description": "Optional profile name."},
                "long_seed": {"type": "boolean", "description": "24 words instead of 12. Only when the user asks for it."}
            }})
        },
    },
    ToolSpec {
        name: "add_profile",
        description: "Add a profile to the current wallet (on an existing mnemonic, at the next unused index). This is the default way to add or create profiles.",
        mutating: true,
        parameters: || {
            json!({"type": "object", "properties": {
                "name": {"type": "string", "description": "Optional profile name."},
                "mnemonic": {"type": "integer", "description": "Mnemonic index. Required when the wallet has more than one mnemonic."}
            }})
        },
    },
    ToolSpec {
        name: "rename_profile",
        description: "Set or clear a profile's name.",
        mutating: true,
        parameters: || {
            json!({"type": "object", "properties": {
                "profile": {"type": "string", "description": "The profile as `mnemonic/profile` (e.g. `0/1`) or its current unique name."},
                "new_name": {"type": "string", "description": "The new name. An empty string clears it."}
            }, "required": ["profile", "new_name"]})
        },
    },
    ToolSpec {
        name: "list_networks",
        description: "Show the unlocked network's networkConfigs (RPC providers); the active one is marked with *.",
        mutating: false,
        parameters: no_params,
    },
];

pub fn spec(name: &str) -> Option<&'static ToolSpec> {
    TOOLS.iter().find(|tool| tool.name == name)
}

fn text(args: &Map<String, Value>, key: &str, required: bool) -> Result<Option<String>, String> {
    let value = match args.get(key) {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.trim().is_empty() => None,
        Some(Value::String(s)) => Some(s.trim().to_owned()),
        Some(_) => return Err(format!("`{key}` must be a string")),
    };
    let Some(value) = value else {
        return if required {
            Err(format!("`{key}` is required"))
        } else {
            Ok(None)
        };
    };
    if value.chars().count() > MAX_TEXT {
        return Err(format!("`{key}` is longer than {MAX_TEXT} characters"));
    }
    if value.chars().any(char::is_control) {
        return Err(format!("`{key}` contains control characters"));
    }
    Ok(Some(value))
}

fn index(args: &Map<String, Value>, key: &str) -> Result<Option<u32>, String> {
    let invalid = || format!("`{key}` must be a non-negative integer");
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        // Models often send numbers as strings.
        Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
        Some(Value::String(s)) => s.trim().parse().map(Some).map_err(|_| invalid()),
        Some(Value::Number(n)) => n
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .map(Some)
            .ok_or_else(invalid),
        Some(_) => Err(invalid()),
    }
}

/// Map a tool call onto `edw` arguments (without the binary itself).
pub fn build_argv(name: &str, args: &Value) -> Result<Vec<String>, String> {
    let empty = Map::new();
    let args = match args {
        Value::Object(map) => map,
        Value::Null => &empty,
        _ => return Err("arguments must be a JSON object".into()),
    };
    let owned = |parts: &[&str]| parts.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();

    Ok(match name {
        "wallet_status" => owned(&["config", "view"]),
        "lock" => owned(&["lock"]),
        "list_profiles" => owned(&["profile", "list"]),
        "list_networks" => owned(&["network", "view"]),
        "unlock" => {
            let network = text(args, "network", false)?
                .unwrap_or_else(|| "sepolia".into())
                .to_lowercase();
            if !NETWORKS.contains(&network.as_str()) {
                return Err(format!("`network` must be one of {}", NETWORKS.join(", ")));
            }
            vec!["unlock".into(), "--network".into(), network]
        }
        "new_mnemonic" => {
            let mut argv = owned(&["profile", "generate"]);
            if let Some(profile_name) = text(args, "name", false)? {
                argv.extend(["--name".into(), profile_name]);
            }
            if args.get("long_seed") == Some(&Value::Bool(true)) {
                argv.push("--long-seed".into());
            }
            argv
        }
        "add_profile" => {
            let mut argv = owned(&["profile", "add", "--next"]);
            if let Some(profile_name) = text(args, "name", false)? {
                argv.extend(["--name".into(), profile_name]);
            }
            if let Some(mnemonic) = index(args, "mnemonic")? {
                argv.extend(["--mnemonic".into(), mnemonic.to_string()]);
            }
            argv
        }
        "rename_profile" => {
            let selector = text(args, "profile", true)?.unwrap_or_default();
            let new_name = text(args, "new_name", false)?.unwrap_or_else(|| "-".into());
            // `--` keeps a value that starts with a dash from being read as a flag.
            vec![
                "profile".into(),
                "rename".into(),
                "--".into(),
                selector,
                new_name,
            ]
        }
        other => return Err(format!("unknown tool `{other}`")),
    })
}

/// A BIP-39 phrase printed on its own line: 12 to 24 lowercase words.
static PHRASE_LINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^\s*(?:[a-z]+\s+){11,23}[a-z]+\s*$").expect("valid regex"));
pub const PHRASE_PLACEHOLDER: &str = "[recovery phrase withheld by the chat harness]";

pub fn redact(output: &str) -> String {
    PHRASE_LINE
        .replace_all(output, PHRASE_PLACEHOLDER)
        .into_owned()
}

#[derive(Clone, Debug)]
pub struct EdwConfig {
    pub binary: PathBuf,
    pub data_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub password: String,
}

impl EdwConfig {
    /// Defaults to a throwaway wallet under `./.edw`, never the user's real edw data dir.
    pub fn from_env() -> Self {
        let var = |key: &str| std::env::var_os(key).map(PathBuf::from);
        let base = PathBuf::from(".edw");
        Self {
            binary: var("EDW_BIN").unwrap_or_else(|| "edw".into()),
            data_dir: var("EDW_DATA_DIR").unwrap_or_else(|| base.join("data")),
            runtime_dir: var("EDW_RUNTIME_DIR").unwrap_or_else(|| base.join("runtime")),
            password: std::env::var("EDW_DECRYPTION_PASSWORD")
                .unwrap_or_else(|_| "edw-tui-demo".into()),
        }
    }
}

pub const EDW_REPO: &str = "https://github.com/ethereum/desktop-wallet";
/// The edw revision the tool mapping is written and tested against. Bumping it means
/// re-running `cargo test --test edw_contract` and fixing [`build_argv`] until it passes.
pub const EDW_PINNED_REV: &str = "038c9944c0efff46082a9d85fdc216fe5e6c738e";

pub fn install_command() -> String {
    format!("cargo install --git {EDW_REPO} --rev {EDW_PINNED_REV} --locked edw")
}

/// Whether the `edw` binary in use is the pinned revision.
#[derive(Debug, PartialEq, Eq)]
pub enum Pin {
    Matches,
    Differs(String),
    /// The binary was not installed by `cargo install --git`, so its revision is unknown.
    Unverified(String),
}

impl Pin {
    pub fn warning(&self) -> Option<String> {
        let pinned = &EDW_PINNED_REV[..7];
        match self {
            Pin::Matches => None,
            Pin::Differs(rev) => Some(format!(
                "edw is at {}, but edw-tui is tested against {pinned}. Install the pinned build: {}",
                &rev[..7.min(rev.len())],
                install_command()
            )),
            Pin::Unverified(reason) => Some(format!(
                "Cannot verify the edw revision ({reason}); edw-tui is tested against {pinned}."
            )),
        }
    }
}

/// The git revision `cargo install` recorded for edw, from `$CARGO_HOME/.crates.toml`.
pub fn installed_rev(crates_toml: &str) -> Option<String> {
    static LINE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#""edw [^ ]+ \(git\+https://github\.com/ethereum/desktop-wallet(?:\?[^#)]*)?#([0-9a-f]{40})\)""#,
        )
        .expect("valid regex")
    });
    LINE.captures(crates_toml).map(|c| c[1].to_owned())
}

/// A bare name is looked up on `PATH`, like `Command` does.
fn resolve_binary(binary: &Path) -> Option<PathBuf> {
    if binary.components().count() > 1 {
        return Some(binary.to_owned());
    }
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(binary))
        .find(|path| path.is_file())
}

pub fn check_pin(binary: &Path) -> Pin {
    let cargo_home = std::env::var_os("CARGO_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cargo")));
    let Some(cargo_home) = cargo_home else {
        return Pin::Unverified("cannot locate CARGO_HOME".into());
    };
    let Some(resolved) = resolve_binary(binary) else {
        return Pin::Unverified(format!("`{}` is not on PATH", binary.display()));
    };
    let canonical = |path: &Path| std::fs::canonicalize(path).ok();
    if canonical(&resolved) != canonical(&cargo_home.join("bin").join("edw")) {
        return Pin::Unverified(format!(
            "{} was not installed by `cargo install`",
            resolved.display()
        ));
    }
    match std::fs::read_to_string(cargo_home.join(".crates.toml"))
        .ok()
        .as_deref()
        .and_then(installed_rev)
    {
        Some(rev) if rev == EDW_PINNED_REV => Pin::Matches,
        Some(rev) => Pin::Differs(rev),
        None => Pin::Unverified("cargo has no git install of edw recorded".into()),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EdwResult {
    pub command: String,
    pub exit_code: i32,
    pub output: String,
}

impl EdwResult {
    pub fn ok(&self) -> bool {
        self.exit_code == 0
    }

    pub fn to_model_json(&self) -> String {
        json!({"command": self.command, "exit_code": self.exit_code, "output": self.output})
            .to_string()
    }
}

pub fn display_command(argv: &[String]) -> String {
    std::iter::once("edw")
        .chain(argv.iter().map(String::as_str))
        .collect::<Vec<_>>()
        .join(" ")
}

pub async fn run(config: &EdwConfig, argv: &[String]) -> EdwResult {
    let command = display_command(argv);
    let fail = |output: String| EdwResult {
        command: command.clone(),
        exit_code: -1,
        output,
    };

    if let Err(error) = std::fs::create_dir_all(&config.runtime_dir) {
        return fail(format!(
            "cannot create {}: {error}",
            config.runtime_dir.display()
        ));
    }
    let child = Command::new(&config.binary)
        .args(argv)
        .env("DATA_DIR", &config.data_dir)
        // edw keeps its unlock session under $XDG_RUNTIME_DIR, which macOS does not set.
        .env("XDG_RUNTIME_DIR", &config.runtime_dir)
        .env("EDW_DECRYPTION_PASSWORD", &config.password)
        .env_remove("RPC_URL")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn();
    let child = match child {
        Ok(child) => child,
        Err(error) => return fail(format!("cannot run {}: {error}", config.binary.display())),
    };
    match tokio::time::timeout(Duration::from_secs(60), child.wait_with_output()).await {
        Err(_) => fail("timed out after 60s".into()),
        Ok(Err(error)) => fail(error.to_string()),
        Ok(Ok(out)) => {
            let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&out.stderr));
            EdwResult {
                command,
                exit_code: out.status.code().unwrap_or(-1),
                output: redact(&text).trim().to_owned(),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(name: &str, args: Value) -> Result<Vec<String>, String> {
        build_argv(name, &args)
    }

    #[test]
    fn maps_every_tool_call_onto_edw_argv() {
        let cases = [
            ("wallet_status", json!({}), "config view"),
            ("lock", Value::Null, "lock"),
            ("list_profiles", json!({}), "profile list"),
            ("list_networks", json!({}), "network view"),
            ("unlock", json!({}), "unlock --network sepolia"),
            (
                "unlock",
                json!({"network": "Mainnet"}),
                "unlock --network mainnet",
            ),
            ("new_mnemonic", json!({}), "profile generate"),
            (
                "new_mnemonic",
                json!({"name": "alice", "long_seed": true}),
                "profile generate --name alice --long-seed",
            ),
            (
                "new_mnemonic",
                json!({"long_seed": "yes"}),
                "profile generate",
            ),
            (
                "add_profile",
                json!({"name": "bob"}),
                "profile add --next --name bob",
            ),
            (
                "add_profile",
                json!({"mnemonic": "1"}),
                "profile add --next --mnemonic 1",
            ),
            (
                "rename_profile",
                json!({"profile": "0/1", "new_name": "savings"}),
                "profile rename -- 0/1 savings",
            ),
            (
                "rename_profile",
                json!({"profile": "bob", "new_name": ""}),
                "profile rename -- bob -",
            ),
        ];
        for (name, args, expected) in cases {
            assert_eq!(argv(name, args).unwrap().join(" "), expected, "{name}");
        }
    }

    #[test]
    fn rejects_calls_that_cannot_map() {
        let cases = [
            ("transfer", json!({"to": "0xabc", "amount": "1"})),
            ("unlock", json!({"network": "goerli"})),
            ("add_profile", json!({"mnemonic": -1})),
            ("add_profile", json!({"mnemonic": true})),
            ("add_profile", json!({"mnemonic": "one"})),
            ("rename_profile", json!({"new_name": "x"})),
            (
                "rename_profile",
                json!({"profile": "bob", "new_name": "a\nb"}),
            ),
            ("new_mnemonic", json!({"name": "x".repeat(65)})),
            ("new_mnemonic", json!({"name": 7})),
            ("list_profiles", json!([1])),
        ];
        for (name, args) in cases {
            assert!(argv(name, args.clone()).is_err(), "{name} {args}");
        }
    }

    #[test]
    fn reads_the_installed_rev_from_cargo_metadata() {
        let crates = format!(
            "[v1]\n\"cargo-edit 0.13.0 (registry+https://github.com/rust-lang/crates.io-index)\" = [\"cargo-add\"]\n\"edw 0.0.1 (git+{EDW_REPO}#{EDW_PINNED_REV})\" = [\"edw\"]\n"
        );
        assert_eq!(installed_rev(&crates).as_deref(), Some(EDW_PINNED_REV));
        let branch =
            format!("\"edw 0.0.1 (git+{EDW_REPO}?branch=main#{EDW_PINNED_REV})\" = [\"edw\"]");
        assert_eq!(installed_rev(&branch).as_deref(), Some(EDW_PINNED_REV));
        assert_eq!(
            installed_rev("\"edw 0.0.1 (path+file:///src)\" = [\"edw\"]"),
            None
        );
        assert!(Pin::Matches.warning().is_none());
        assert!(
            Pin::Differs("a".repeat(40))
                .warning()
                .unwrap()
                .contains("--rev 038c994")
        );
    }

    #[test]
    fn every_spec_maps() {
        for tool in &TOOLS {
            let args = if tool.name == "rename_profile" {
                json!({"profile": "0/0", "new_name": "x"})
            } else {
                json!({})
            };
            assert!(build_argv(tool.name, &args).is_ok(), "{}", tool.name);
            assert_eq!((tool.parameters)()["type"], "object");
        }
    }

    #[test]
    fn redacts_recovery_phrases_only() {
        let twelve = [["abandon"; 11].join(" "), "about".into()].join(" ");
        let twenty_four = ["zoo"; 24].join(" ");
        let out = format!(
            "Write this recovery phrase down now.\n\n{twelve}\n\n{twenty_four}\nCreated mnemonic 1 and profile 1/0 (alice)."
        );
        let redacted = redact(&out);
        assert!(!redacted.contains("abandon") && !redacted.contains("zoo"));
        assert_eq!(redacted.matches(PHRASE_PLACEHOLDER).count(), 2);
        assert!(redacted.contains("Created mnemonic 1 and profile 1/0 (alice)."));
        let plain = "Unlocked sepolia. Run `edw lock` to lock the wallet.";
        assert_eq!(redact(plain), plain);
    }
}
