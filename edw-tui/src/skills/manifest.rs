//! A skill folder: `SKILL.md` (frontmatter + the text the model reads) and, optionally,
//! `skill.toml` (what the harness enforces: contracts, functions, tokens, hosts, tools).
//!
//! A folder without `skill.toml` is a knowledge-only skill: instructions over built-in tools.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Component, Path, PathBuf},
    time::Duration,
};

use alloy_json_abi::Function;
use alloy_primitives::Address;
use serde::Deserialize;
use serde_json::Value;

/// The most of `SKILL.md`'s body the model is given.
pub const MAX_BODY: usize = 4 * 1024;

#[derive(Clone, Debug)]
pub struct Skill {
    pub name: String,
    pub description: String,
    pub body: String,
    pub dir: PathBuf,
    pub manifest: Manifest,
}

#[derive(Clone, Debug, Default)]
pub struct Manifest {
    pub version: String,
    pub requires: Vec<String>,
    pub hosts: Vec<String>,
    pub contracts: Vec<ContractDef>,
    pub tokens: Vec<TokenDef>,
    pub read_tools: Vec<ToolDef>,
    pub actions: Vec<ActionDef>,
}

/// A contract a plan may call: only the listed functions, only at the pinned addresses.
#[derive(Clone, Debug)]
pub struct ContractDef {
    pub id: String,
    pub label: String,
    pub functions: Vec<Function>,
    pub address: BTreeMap<u64, Address>,
}

/// An ERC-20 the skill names. `movable` tokens may be approved by a plan; the others are only
/// listed so the review can name them in the simulated changes.
#[derive(Clone, Debug)]
pub struct TokenDef {
    pub id: String,
    pub symbol: String,
    pub decimals: u8,
    pub address: BTreeMap<u64, Address>,
    pub movable: bool,
}

#[derive(Clone, Debug)]
pub struct ToolDef {
    pub name: String,
    /// Relative to the skill folder, never outside it.
    pub run: String,
    pub description: String,
    pub schema: Value,
    /// URL prefix → how long a response stays cached.
    pub cache: BTreeMap<String, Duration>,
}

#[derive(Clone, Debug)]
pub struct ActionDef {
    pub tool: ToolDef,
    /// Contract ids this action may approve as spender.
    pub approves: Vec<String>,
}

impl Skill {
    pub fn has_scripts(&self) -> bool {
        !self.manifest.read_tools.is_empty() || !self.manifest.actions.is_empty()
    }

    /// Read tools first, then actions, in manifest order.
    pub fn tool_names(&self) -> Vec<&str> {
        let m = &self.manifest;
        m.read_tools
            .iter()
            .chain(m.actions.iter().map(|a| &a.tool))
            .map(|t| t.name.as_str())
            .collect()
    }

    pub fn read_tool(&self, name: &str) -> Option<&ToolDef> {
        self.manifest.read_tools.iter().find(|t| t.name == name)
    }

    pub fn action(&self, name: &str) -> Option<&ActionDef> {
        self.manifest.actions.iter().find(|a| a.tool.name == name)
    }
}

impl Manifest {
    pub fn contract(&self, id: &str) -> Option<&ContractDef> {
        self.contracts.iter().find(|c| c.id == id)
    }

    pub fn token(&self, id: &str) -> Option<&TokenDef> {
        self.tokens.iter().find(|t| t.id == id)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawManifest {
    version: String,
    #[serde(default)]
    requires: Vec<String>,
    #[serde(default)]
    hosts: Vec<String>,
    #[serde(default, rename = "contract")]
    contracts: Vec<RawContract>,
    #[serde(default, rename = "token")]
    tokens: Vec<RawToken>,
    #[serde(default, rename = "read_tool")]
    read_tools: Vec<RawTool>,
    #[serde(default, rename = "action")]
    actions: Vec<RawTool>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawContract {
    id: String,
    label: Option<String>,
    functions: Vec<String>,
    address: BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawToken {
    id: String,
    symbol: String,
    decimals: u8,
    address: BTreeMap<String, String>,
    #[serde(default = "yes")]
    movable: bool,
}

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawTool {
    name: String,
    run: String,
    description: String,
    schema: Value,
    #[serde(default)]
    cache: BTreeMap<String, String>,
    /// Actions only.
    #[serde(default)]
    approves: Vec<String>,
}

/// Reads and validates one skill folder. Errors name the file and the field at fault.
pub fn load(dir: &Path) -> Result<Skill, String> {
    // Absolute from here on: it is mounted into Docker, which reads a relative `-v` source as
    // a volume name.
    let dir = &fs::canonicalize(dir)
        .map_err(|e| format!("{}: cannot open the skill folder ({e})", dir.display()))?;
    let folder = dir
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| format!("{}: not a folder name", dir.display()))?
        .to_owned();
    let md = fs::read_to_string(dir.join("SKILL.md"))
        .map_err(|e| format!("{folder}: cannot read SKILL.md ({e})"))?;
    let (front, body) = frontmatter(&md).ok_or_else(|| {
        format!("{folder}/SKILL.md: needs YAML frontmatter between two `---` lines")
    })?;
    let field = |key: &str| {
        front
            .get(key)
            .filter(|v| !v.is_empty())
            .cloned()
            .ok_or_else(|| format!("{folder}/SKILL.md: frontmatter needs a {key}"))
    };
    let name = field("name")?;
    let description = field("description")?;
    if name != folder {
        return Err(format!(
            "{folder}/SKILL.md: name `{name}` must match its folder `{folder}`"
        ));
    }
    if body.len() > MAX_BODY {
        return Err(format!(
            "{folder}/SKILL.md: the body is {} bytes, at most 4 KiB",
            body.len()
        ));
    }
    let toml_path = dir.join("skill.toml");
    let manifest = if toml_path.exists() {
        let text = fs::read_to_string(&toml_path)
            .map_err(|e| format!("{folder}/skill.toml: cannot read ({e})"))?;
        let raw: RawManifest =
            toml::from_str(&text).map_err(|e| format!("{folder}/skill.toml: {e}"))?;
        validate(raw).map_err(|e| format!("{folder}/skill.toml: {e}"))?
    } else {
        Manifest {
            version: "0".into(),
            ..Manifest::default()
        }
    };
    Ok(Skill {
        name,
        description,
        body: body.to_owned(),
        dir: dir.to_owned(),
        manifest,
    })
}

/// `key: value` lines between the first two `---` lines; indented lines continue a value.
fn frontmatter(text: &str) -> Option<(BTreeMap<String, String>, &str)> {
    let rest = text.strip_prefix("---\n")?;
    let end = rest.find("\n---")?;
    let head = &rest[..end];
    let tail = &rest[end + 4..];
    let body = tail.strip_prefix('\n').unwrap_or(tail);
    let mut map = BTreeMap::new();
    let mut last: Option<String> = None;
    for line in head.lines() {
        if line.starts_with([' ', '\t']) {
            let value: &mut String = map.get_mut(last.as_ref()?)?;
            value.push(' ');
            value.push_str(line.trim());
            continue;
        }
        let (key, value) = line.split_once(':')?;
        let key = key.trim().to_owned();
        map.insert(key.clone(), value.trim().to_owned());
        last = Some(key);
    }
    Some((map, body))
}

fn addresses(owner: &str, raw: BTreeMap<String, String>) -> Result<BTreeMap<u64, Address>, String> {
    raw.into_iter()
        .map(|(chain, address)| {
            let chain: u64 = chain
                .parse()
                .map_err(|_| format!("{owner}: `{chain}` is not a chain id"))?;
            let address: Address = address
                .parse()
                .map_err(|_| format!("{owner}: `{address}` is not an address"))?;
            Ok((chain, address))
        })
        .collect()
}

/// `30s`, `15m`, `1h`.
fn duration(text: &str) -> Option<Duration> {
    let (number, unit) = text.split_at(text.find(|c: char| !c.is_ascii_digit())?);
    let n: u64 = number.parse().ok()?;
    let secs = match unit {
        "s" => n,
        "m" => n * 60,
        "h" => n * 3600,
        _ => return None,
    };
    Some(Duration::from_secs(secs))
}

fn tool(raw: RawTool) -> Result<ToolDef, String> {
    let RawTool {
        name,
        run,
        description,
        schema,
        cache,
        ..
    } = raw;
    if run.is_empty()
        || Path::new(&run)
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err(format!(
            "{name}: run `{run}` must be a path inside the skill folder"
        ));
    }
    if !schema.is_object() {
        return Err(format!("{name}: schema must be a JSON Schema object"));
    }
    let cache = cache
        .into_iter()
        .map(|(prefix, ttl)| {
            duration(&ttl)
                .map(|d| (prefix, d))
                .ok_or_else(|| format!("{name}: cache TTL `{ttl}` must look like 30s, 15m or 1h"))
        })
        .collect::<Result<_, _>>()?;
    Ok(ToolDef {
        name,
        run,
        description,
        schema,
        cache,
    })
}

fn validate(raw: RawManifest) -> Result<Manifest, String> {
    let mut ids = BTreeSet::new();
    let mut contracts = Vec::new();
    for c in raw.contracts {
        if !ids.insert(c.id.clone()) {
            return Err(format!("duplicate id `{}`", c.id));
        }
        let functions = c
            .functions
            .iter()
            .map(|sig| Function::parse(sig).map_err(|e| format!("{}: `{sig}`: {e}", c.id)))
            .collect::<Result<Vec<_>, _>>()?;
        contracts.push(ContractDef {
            label: c.label.unwrap_or_else(|| c.id.clone()),
            address: addresses(&c.id, c.address)?,
            id: c.id,
            functions,
        });
    }
    let mut tokens = Vec::new();
    for t in raw.tokens {
        if !ids.insert(t.id.clone()) {
            return Err(format!("duplicate id `{}`", t.id));
        }
        tokens.push(TokenDef {
            address: addresses(&t.id, t.address)?,
            id: t.id,
            symbol: t.symbol,
            decimals: t.decimals,
            movable: t.movable,
        });
    }
    let mut names = BTreeSet::new();
    let mut read_tools = Vec::new();
    for t in raw.read_tools {
        if !names.insert(t.name.clone()) {
            return Err(format!("duplicate tool `{}`", t.name));
        }
        if !t.approves.is_empty() {
            return Err(format!("{}: only actions may approve", t.name));
        }
        read_tools.push(tool(t)?);
    }
    let mut actions = Vec::new();
    for a in raw.actions {
        if !names.insert(a.name.clone()) {
            return Err(format!("duplicate tool `{}`", a.name));
        }
        if let Some(spender) = a
            .approves
            .iter()
            .find(|s| !contracts.iter().any(|c| &c.id == *s))
        {
            return Err(format!(
                "{}: approves `{spender}`, which is not a contract in this manifest",
                a.name
            ));
        }
        actions.push(ActionDef {
            approves: a.approves.clone(),
            tool: tool(a)?,
        });
    }
    Ok(Manifest {
        version: raw.version,
        requires: raw.requires,
        hosts: raw.hosts,
        contracts,
        tokens,
        read_tools,
        actions,
    })
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use alloy_primitives::address;

    use super::*;

    const SKILL_MD: &str = "---
name: demo
description: Look up yields and lend
  stablecoins on Aave.
---
Call demo_read first.
";

    const SKILL_TOML: &str = r#"
version = "0.1.0"
requires = ["defi-data"]
hosts = ["yields.llama.fi"]

[[contract]]
id = "pool"
label = "Aave Pool"
functions = ["function supply(address asset,uint256 amount,address onBehalfOf,uint16 referralCode)"]
address = { 11155111 = "0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951", 1 = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2" }

[[token]]
id = "usdc"
symbol = "USDC"
decimals = 6
address = { 1 = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" }

[[token]]
id = "ausdc"
symbol = "aUSDC"
decimals = 6
movable = false
address = { 1 = "0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c" }

[[read_tool]]
name = "demo_read"
run = "scripts/read.py"
description = "Reads."
schema = { type = "object", properties = {} }
cache = { "https://yields.llama.fi/pools" = "15m" }

[[action]]
name = "demo_supply"
run = "scripts/supply.py"
description = "Supplies."
schema = { type = "object", properties = { amount = { type = "string" } } }
approves = ["pool"]
"#;

    fn folder(root: &Path, name: &str, md: &str, toml: Option<&str>) -> std::path::PathBuf {
        let dir = root.join(name);
        fs::create_dir_all(dir.join("scripts")).unwrap();
        fs::write(dir.join("SKILL.md"), md).unwrap();
        if let Some(toml) = toml {
            fs::write(dir.join("skill.toml"), toml).unwrap();
        }
        dir
    }

    fn load_err(md: &str, toml: Option<&str>) -> String {
        let root = tempfile::tempdir().unwrap();
        let dir = folder(root.path(), "demo", md, toml);
        match load(&dir) {
            Ok(_) => panic!("expected an error"),
            Err(error) => error,
        }
    }

    #[test]
    fn a_full_skill_loads() {
        let root = tempfile::tempdir().unwrap();
        let dir = folder(root.path(), "demo", SKILL_MD, Some(SKILL_TOML));
        let skill = load(&dir).unwrap();
        assert_eq!(skill.name, "demo");
        assert_eq!(
            skill.description,
            "Look up yields and lend stablecoins on Aave."
        );
        assert_eq!(skill.body.trim(), "Call demo_read first.");
        let m = &skill.manifest;
        assert_eq!(m.version, "0.1.0");
        assert_eq!(m.requires, ["defi-data"]);
        assert_eq!(m.hosts, ["yields.llama.fi"]);
        let pool = m.contract("pool").unwrap();
        assert_eq!(pool.label, "Aave Pool");
        assert_eq!(pool.functions[0].name, "supply");
        assert_eq!(pool.functions[0].inputs.len(), 4);
        assert_eq!(
            pool.address[&1],
            address!("0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2")
        );
        assert!(m.token("usdc").unwrap().movable);
        assert!(!m.token("ausdc").unwrap().movable);
        assert_eq!(m.token("usdc").unwrap().decimals, 6);
        assert_eq!(
            m.read_tools[0].cache["https://yields.llama.fi/pools"],
            Duration::from_secs(900)
        );
        assert_eq!(m.actions[0].approves, ["pool"]);
        assert!(skill.has_scripts());
        assert_eq!(skill.tool_names(), ["demo_read", "demo_supply"]);
    }

    #[test]
    fn a_folder_without_skill_toml_is_knowledge_only() {
        let root = tempfile::tempdir().unwrap();
        let dir = folder(root.path(), "demo", SKILL_MD, None);
        let skill = load(&dir).unwrap();
        assert!(!skill.has_scripts());
        assert!(skill.tool_names().is_empty());
        assert_eq!(skill.manifest.version, "0");
    }

    #[test]
    fn frontmatter_is_required_and_must_name_the_folder() {
        assert!(load_err("no frontmatter", None).contains("frontmatter"));
        assert!(load_err("---\ndescription: x\n---\n", None).contains("name"));
        assert!(load_err("---\nname: demo\n---\n", None).contains("description"));
        assert!(load_err("---\nname: other\ndescription: x\n---\n", None).contains("folder"));
    }

    #[test]
    fn a_long_body_is_refused() {
        let md = format!("---\nname: demo\ndescription: x\n---\n{}", "a".repeat(5000));
        assert!(load_err(&md, None).contains("4 KiB"));
    }

    #[test]
    fn bad_manifests_are_refused_with_the_field() {
        let bad =
            |from: &str, to: &str| load_err(SKILL_MD, Some(&SKILL_TOML.replacen(from, to, 1)));
        assert!(bad("0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951", "0x1234").contains("pool"));
        assert!(bad("function supply(", "function supply(nonsense ").contains("supply"));
        assert!(bad("scripts/read.py", "../read.py").contains("demo_read"));
        assert!(bad("scripts/read.py", "/etc/passwd").contains("demo_read"));
        assert!(bad("id = \"ausdc\"", "id = \"usdc\"").contains("duplicate"));
        assert!(bad("approves = [\"pool\"]", "approves = [\"router\"]").contains("router"));
        assert!(bad("name = \"demo_supply\"", "name = \"demo_read\"").contains("duplicate"));
        assert!(bad("11155111 = ", "sepolia = ").contains("chain"));
        assert!(bad("\"15m\"", "\"soon\"").contains("cache"));
    }
}
