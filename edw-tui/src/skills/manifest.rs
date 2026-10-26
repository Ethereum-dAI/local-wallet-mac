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

use alloy_json_abi::{Function, StateMutability};
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
    pub review_reads: Vec<ReviewRead>,
}

/// A view call every action's review shows, run in the plan's own simulation before the plan
/// and after it (an Aave account's debt and health factor, say), so those numbers come from the
/// harness and never from the skill.
#[derive(Clone, Debug, PartialEq)]
pub struct ReviewRead {
    pub label: String,
    pub contract: String,
    pub function: Function,
    /// Like a call's: `$self`, manifest ids, plain decimals.
    pub args: Vec<Value>,
    /// The uint outputs shown, in the function's order.
    pub show: Vec<Shown>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shown {
    pub output: usize,
    pub name: String,
    pub decimals: u8,
    pub unit: Option<String>,
}

/// A contract a plan may call: only the listed functions, only at the pinned addresses.
#[derive(Clone, Debug)]
pub struct ContractDef {
    pub id: String,
    pub label: String,
    pub functions: Vec<Function>,
    pub address: BTreeMap<u64, Address>,
    /// Instead of a pinned address: the name of the action argument that holds it. The address
    /// then comes from what the user asked for, never from the script, and a call to it is only
    /// as wide as `functions`. For a contract each user has their own copy of, such as a Safe.
    pub address_arg: Option<String>,
    /// Functions that may take raw `bytes`, and addresses the manifest does not know, because the
    /// contract itself rejects the call unless the owners signed exactly those arguments (a
    /// Safe's `execTransaction`). The review shows the arguments; the signatures are the check.
    pub signed_calls: Vec<String>,
    /// function → uint parameter → the address parameter holding its token, or a token id when
    /// the function's token is implied, so the review can show that amount in the token's units
    /// (`amount=2.5 USDC (2500000)`).
    pub amounts: BTreeMap<String, BTreeMap<String, String>>,
    /// function → address parameters that must be the sender (`$self`): where the funds of a
    /// call go, so a plan cannot pay out to a token or contract of the manifest instead.
    pub self_only: BTreeMap<String, Vec<String>>,
}

/// A token the skill names, and what a plan may grant on it.
#[derive(Clone, Debug)]
pub struct TokenDef {
    pub id: String,
    pub symbol: String,
    pub decimals: u8,
    pub address: BTreeMap<u64, Address>,
    pub approval: Approval,
}

/// What a plan's approve step may grant on a token, and to which contracts of the manifest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Approval {
    /// Never: the token is listed so the review can name it in the simulated changes.
    Never,
    /// ERC-20 `approve`, to any spender the action lists or, with `only`, just to those.
    Allowance { only: Option<Vec<String>> },
    /// Credit delegation of an Aave debt token (`approveDelegation`): the delegate may borrow up
    /// to the amount in the sender's name. Only to the listed contracts.
    Delegation { to: Vec<String> },
}

impl Approval {
    /// Whether a plan may grant this to the contract `spender`.
    pub fn allows(&self, spender: &str) -> bool {
        match self {
            Self::Never => false,
            Self::Allowance { only: None } => true,
            Self::Allowance { only: Some(ids) } | Self::Delegation { to: ids } => {
                ids.iter().any(|id| id == spender)
            }
        }
    }
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
    #[serde(default, rename = "review_read")]
    review_reads: Vec<RawReviewRead>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawReviewRead {
    label: String,
    contract: String,
    function: String,
    #[serde(default)]
    args: Vec<Value>,
    /// output name → `"<decimals>"` or `"<decimals> <unit>"`, e.g. `"8 USD"`.
    show: BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawContract {
    id: String,
    label: Option<String>,
    functions: Vec<String>,
    #[serde(default)]
    address: BTreeMap<String, String>,
    address_arg: Option<String>,
    #[serde(default)]
    signed_calls: Vec<String>,
    #[serde(default)]
    amounts: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    self_only: BTreeMap<String, Vec<String>>,
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
    approve_to: Option<Vec<String>>,
    #[serde(default)]
    kind: TokenKind,
}

#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "lowercase")]
enum TokenKind {
    #[default]
    Erc20,
    /// An Aave debt token: not transferable, approved by credit delegation.
    Debt,
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
    if description.chars().any(char::is_control) {
        return Err(format!(
            "{folder}/SKILL.md: the description contains a control character"
        ));
    }
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

/// What a plan may grant on token `t`: `movable = false` is never, `kind = "debt"` is a credit
/// delegation, which must name its delegates, and `approve_to` narrows an ERC-20's spenders.
fn approval(t: &RawToken, contracts: &[ContractDef]) -> Result<Approval, String> {
    let id = &t.id;
    if let Some(to) = &t.approve_to {
        if to.is_empty() {
            return Err(format!(
                "{id}: approve_to is empty; write `movable = false` for a token that is never approved"
            ));
        }
        for spender in to {
            match contracts.iter().find(|c| &c.id == spender) {
                None => {
                    return Err(format!(
                        "{id}: approve_to names `{spender}`, which is not a contract in this manifest"
                    ));
                }
                Some(c) if c.address_arg.is_some() => {
                    return Err(format!(
                        "{id}: approve_to names `{spender}`, whose address the user names; only a pinned contract may be approved"
                    ));
                }
                Some(_) => {}
            }
        }
    }
    match (t.movable, t.kind, t.approve_to.clone()) {
        (false, _, Some(_)) => Err(format!(
            "{id}: give `movable = false` or `approve_to`, not both"
        )),
        (false, _, None) => Ok(Approval::Never),
        (true, TokenKind::Erc20, only) => Ok(Approval::Allowance { only }),
        (true, TokenKind::Debt, Some(to)) => Ok(Approval::Delegation { to }),
        (true, TokenKind::Debt, None) => Err(format!(
            "{id}: a debt token is delegated only to the contracts in `approve_to`; list them, or write `movable = false`"
        )),
    }
}

/// Token functions that grant or move funds directly. Plans approve only through the checker's
/// own exact-amount step, so a manifest may not list these.
const MOVES_TOKENS: [&str; 15] = [
    "approve",
    "increaseallowance",
    "decreaseallowance",
    "increaseapproval",
    "decreaseapproval",
    "authorizeoperator",
    "permit",
    "transfer",
    "transferfrom",
    "safetransferfrom",
    "setapprovalforall",
    "approveandcall",
    "transferandcall",
    "approvedelegation",
    "delegationwithsig",
];

/// A function a plan could use to get around the checker: one that moves or approves tokens
/// itself, or takes raw `bytes` (multicall-style), whose contents the checker cannot see.
fn sidesteps_the_checker(function: &Function, signed: bool) -> Option<String> {
    use alloy_dyn_abi::{DynSolType, Specifier};
    fn raw_bytes(ty: &DynSolType) -> bool {
        match ty {
            DynSolType::Bytes => true,
            DynSolType::Array(inner) | DynSolType::FixedArray(inner, _) => raw_bytes(inner),
            DynSolType::Tuple(items) => items.iter().any(raw_bytes),
            _ => false,
        }
    }
    if MOVES_TOKENS.contains(&function.name.to_lowercase().as_str()) {
        return Some(format!(
            "{} is not allowed: plans approve and move tokens only through the checked approve step",
            function.name
        ));
    }
    let bytes = !signed
        && function
            .inputs
            .iter()
            .any(|p| p.resolve().is_ok_and(|ty| raw_bytes(&ty)));
    bytes.then(|| {
        format!(
            "{} is not allowed: it takes raw bytes, which the plan checker cannot inspect",
            function.name
        )
    })
}

/// Every `amounts` entry names a listed function, one of its uint parameters, and one of its
/// address parameters (the token) or one of the manifest's token ids.
fn check_amounts(
    contract: &str,
    functions: &[Function],
    amounts: &BTreeMap<String, BTreeMap<String, String>>,
    token_ids: &BTreeSet<&str>,
) -> Result<(), String> {
    for (name, params) in amounts {
        let function = functions.iter().find(|f| &f.name == name).ok_or_else(|| {
            format!("{contract}: amounts names {name}, which is not in functions")
        })?;
        let ty = |param: &str| {
            function
                .inputs
                .iter()
                .find(|p| p.name == param)
                .map(|p| p.ty.clone())
                .ok_or_else(|| {
                    format!(
                        "{contract}: amounts.{name} names `{param}`, which {name} does not take"
                    )
                })
        };
        for (amount, token) in params {
            if !ty(amount)?.starts_with("uint") {
                return Err(format!(
                    "{contract}: amounts.{name}.{amount} must be a uint parameter"
                ));
            }
            if !function.inputs.iter().any(|p| &p.name == token) {
                if token_ids.contains(token.as_str()) {
                    continue;
                }
                return Err(format!(
                    "{contract}: amounts.{name}.{amount} names `{token}`, which is neither a parameter of {name} nor a token id"
                ));
            }
            if ty(token)? != "address" {
                return Err(format!(
                    "{contract}: amounts.{name}.{amount} must point at an address parameter, not `{token}`"
                ));
            }
        }
    }
    Ok(())
}

/// Text shown on the consent screen or in the review must be one line, with no terminal
/// escapes: a control character could fake or hide lines there.
fn single_line(raw: &RawManifest) -> Result<(), String> {
    let mut fields: Vec<(&str, &str)> = vec![("version", &raw.version)];
    fields.extend(raw.hosts.iter().map(|h| ("hosts", h.as_str())));
    for c in &raw.contracts {
        fields.push(("contract id", &c.id));
        if let Some(label) = &c.label {
            fields.push(("contract label", label));
        }
    }
    for t in &raw.tokens {
        fields.push(("token id", &t.id));
        fields.push(("token symbol", &t.symbol));
    }
    for t in raw.read_tools.iter().chain(&raw.actions) {
        fields.push(("tool name", &t.name));
        fields.push(("tool description", &t.description));
    }
    for r in &raw.review_reads {
        fields.push(("review_read label", &r.label));
        fields.extend(r.show.iter().flat_map(|(name, spec)| {
            [
                ("review_read show", name.as_str()),
                ("review_read show", spec),
            ]
        }));
    }
    match fields
        .iter()
        .find(|(_, text)| text.chars().any(char::is_control))
    {
        Some((field, text)) => Err(format!("{field} {:?} contains a control character", text)),
        None => Ok(()),
    }
}

fn validate(raw: RawManifest) -> Result<Manifest, String> {
    single_line(&raw)?;
    let token_ids: BTreeSet<&str> = raw.tokens.iter().map(|t| t.id.as_str()).collect();
    let mut ids = BTreeSet::new();
    let mut contracts = Vec::new();
    for c in raw.contracts {
        if !ids.insert(c.id.clone()) {
            return Err(format!("duplicate id `{}`", c.id));
        }
        let functions = c
            .functions
            .iter()
            .map(|sig| {
                let function =
                    Function::parse(sig).map_err(|e| format!("{}: `{sig}`: {e}", c.id))?;
                match sidesteps_the_checker(&function, c.signed_calls.contains(&function.name)) {
                    Some(why) => Err(format!("{}: {why}", c.id)),
                    None => Ok(function),
                }
            })
            .collect::<Result<Vec<_>, _>>()?;
        check_amounts(&c.id, &functions, &c.amounts, &token_ids)?;
        for (name, params) in &c.self_only {
            let function = functions.iter().find(|f| &f.name == name).ok_or_else(|| {
                format!(
                    "{}: self_only names {name}, which is not in functions",
                    c.id
                )
            })?;
            if let Some(param) = params.iter().find(|p| {
                !function
                    .inputs
                    .iter()
                    .any(|i| &i.name == *p && i.ty == "address")
            }) {
                return Err(format!(
                    "{}: self_only.{name} names `{param}`, which is not an address parameter of {name}",
                    c.id
                ));
            }
        }
        if !c.signed_calls.is_empty() && c.address_arg.is_none() {
            return Err(format!(
                "{}: signed_calls is only for a contract at an address the user names (address_arg); a pinned contract may not take raw bytes",
                c.id
            ));
        }
        if let Some(name) = c
            .signed_calls
            .iter()
            .find(|n| !functions.iter().any(|f| &f.name == *n))
        {
            return Err(format!(
                "{}: signed_calls names `{name}`, which is not a listed function",
                c.id
            ));
        }
        match (&c.address_arg, c.address.is_empty()) {
            (Some(_), false) => {
                return Err(format!(
                    "{}: give `address` or `address_arg`, not both",
                    c.id
                ));
            }
            (None, true) => {
                return Err(format!("{}: needs an `address` or an `address_arg`", c.id));
            }
            _ => {}
        }
        contracts.push(ContractDef {
            address_arg: c.address_arg,
            signed_calls: c.signed_calls,
            amounts: c.amounts,
            self_only: c.self_only,
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
            approval: approval(&t, &contracts)?,
            address: addresses(&t.id, t.address)?,
            id: t.id,
            symbol: t.symbol,
            decimals: t.decimals,
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
        if let Some(spender) = a.approves.iter().find(|s| {
            contracts
                .iter()
                .any(|c| &c.id == *s && c.address_arg.is_some())
        }) {
            return Err(format!(
                "{}: approves `{spender}`, whose address the user names; only a pinned contract may be approved",
                a.name
            ));
        }
        actions.push(ActionDef {
            approves: a.approves.clone(),
            tool: tool(a)?,
        });
    }
    let review_reads = raw
        .review_reads
        .into_iter()
        .map(|r| review_read(r, &contracts))
        .collect::<Result<_, _>>()?;
    Ok(Manifest {
        version: raw.version,
        requires: raw.requires,
        hosts: raw.hosts,
        contracts,
        tokens,
        read_tools,
        actions,
        review_reads,
    })
}

/// A review read calls a view function of a manifest contract, and shows only uint outputs it
/// names, each as `"<decimals>"` or `"<decimals> <unit>"`.
fn review_read(raw: RawReviewRead, contracts: &[ContractDef]) -> Result<ReviewRead, String> {
    let label = &raw.label;
    if !contracts.iter().any(|c| c.id == raw.contract) {
        return Err(format!(
            "review_read {label}: `{}` is not a contract in this manifest",
            raw.contract
        ));
    }
    let function = Function::parse(&raw.function)
        .map_err(|e| format!("review_read {label}: `{}`: {e}", raw.function))?;
    if !matches!(
        function.state_mutability,
        StateMutability::View | StateMutability::Pure
    ) {
        return Err(format!(
            "review_read {label}: {} must be a view function",
            function.name
        ));
    }
    if raw.args.len() != function.inputs.len() {
        return Err(format!(
            "review_read {label}: {} takes {} arguments, got {}",
            function.name,
            function.inputs.len(),
            raw.args.len()
        ));
    }
    if raw.show.is_empty() {
        return Err(format!(
            "review_read {label}: `show` names no output to show"
        ));
    }
    for name in raw.show.keys() {
        match function.outputs.iter().find(|o| &o.name == name) {
            Some(o) if o.ty.starts_with("uint") => {}
            Some(_) => {
                return Err(format!(
                    "review_read {label}: `{name}` is not a uint output"
                ));
            }
            None => {
                return Err(format!(
                    "review_read {label}: {} has no output named `{name}`",
                    function.name
                ));
            }
        }
    }
    let show = function
        .outputs
        .iter()
        .enumerate()
        .filter_map(|(output, o)| Some((output, o, raw.show.get(&o.name)?)))
        .map(|(output, o, spec)| {
            let (decimals, unit) = spec.split_once(' ').unwrap_or((spec, ""));
            let decimals = decimals.parse().map_err(|_| {
                format!(
                    "review_read {label}: show.{} must be \"<decimals>\" or \"<decimals> <unit>\", not `{spec}`",
                    o.name
                )
            })?;
            Ok(Shown {
                output,
                name: o.name.clone(),
                decimals,
                unit: (!unit.is_empty()).then(|| unit.to_owned()),
            })
        })
        .collect::<Result<_, String>>()?;
    Ok(ReviewRead {
        label: raw.label,
        contract: raw.contract,
        function,
        args: raw.args,
        show,
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
        assert_eq!(
            m.token("usdc").unwrap().approval,
            Approval::Allowance { only: None }
        );
        assert_eq!(m.token("ausdc").unwrap().approval, Approval::Never);
        assert_eq!(m.token("usdc").unwrap().decimals, 6);
        assert_eq!(
            m.read_tools[0].cache["https://yields.llama.fi/pools"],
            Duration::from_secs(900)
        );
        assert_eq!(m.actions[0].approves, ["pool"]);
        assert!(skill.has_scripts());
        assert_eq!(skill.tool_names(), ["demo_read", "demo_supply"]);
    }

    /// `approve_to` narrows to whom a token may be approved; a `debt` token is approved by credit
    /// delegation and must name its delegates; `movable = false` is never approved.
    #[test]
    fn token_approval_policies() {
        let with = |token: &str| {
            let toml = format!(
                "{SKILL_TOML}\n[[contract]]\nid = \"gateway\"\nfunctions = [\"function depositETH(address pool,address onBehalfOf,uint16 referralCode) payable\"]\naddress = {{ 1 = \"0xd01607c3C5eCABa394D8be377a08590149325722\" }}\n\n[[token]]\nid = \"t\"\nsymbol = \"T\"\ndecimals = 18\naddress = {{ 1 = \"0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8\" }}\n{token}\n"
            );
            let root = tempfile::tempdir().unwrap();
            let dir = folder(root.path(), "demo", SKILL_MD, Some(&toml));
            load(&dir).map(|s| s.manifest.token("t").unwrap().approval.clone())
        };
        let gateway = || vec!["gateway".to_owned()];
        assert_eq!(
            with("approve_to = [\"gateway\"]").unwrap(),
            Approval::Allowance {
                only: Some(gateway())
            }
        );
        assert_eq!(
            with("kind = \"debt\"\napprove_to = [\"gateway\"]").unwrap(),
            Approval::Delegation { to: gateway() }
        );
        assert_eq!(
            with("kind = \"debt\"\nmovable = false").unwrap(),
            Approval::Never
        );
        for (token, needle) in [
            ("kind = \"debt\"", "debt token"),
            ("movable = false\napprove_to = [\"gateway\"]", "not both"),
            ("approve_to = []", "empty"),
            ("approve_to = [\"router\"]", "router"),
            ("kind = \"nft\"", "kind"),
        ] {
            let error = with(token).unwrap_err();
            assert!(error.contains(needle), "{token}: {error}");
        }
        let a = Approval::Allowance {
            only: Some(gateway()),
        };
        assert!(a.allows("gateway") && !a.allows("pool"));
        assert!(Approval::Allowance { only: None }.allows("pool"));
        assert!(!Approval::Never.allows("pool"));
        assert!(!Approval::Delegation { to: gateway() }.allows("pool"));
    }

    const ACCOUNT: &str = r#"
[[review_read]]
label = "Aave account"
contract = "pool"
function = "function getUserAccountData(address user) view returns (uint256 collateral,uint256 debt,uint256 canBorrow,uint256 liquidationThreshold,uint256 ltv,uint256 healthFactor)"
args = ["$self"]
show = { healthFactor = "18", collateral = "8 USD" }
"#;

    #[test]
    fn a_review_read_shows_the_uint_outputs_it_names_in_function_order() {
        let root = tempfile::tempdir().unwrap();
        let toml = format!("{SKILL_TOML}{ACCOUNT}");
        let dir = folder(root.path(), "demo", SKILL_MD, Some(&toml));
        let skill = load(&dir).unwrap();
        let read = &skill.manifest.review_reads[0];
        assert_eq!(read.label, "Aave account");
        assert_eq!(read.contract, "pool");
        assert_eq!(read.function.name, "getUserAccountData");
        assert_eq!(read.args, [Value::String("$self".into())]);
        assert_eq!(
            read.show,
            [
                Shown {
                    output: 0,
                    name: "collateral".into(),
                    decimals: 8,
                    unit: Some("USD".into())
                },
                Shown {
                    output: 5,
                    name: "healthFactor".into(),
                    decimals: 18,
                    unit: None
                },
            ]
        );
    }

    #[test]
    fn a_review_read_must_be_a_view_of_a_manifest_contract_showing_uints() {
        let bad = |from: &str, to: &str| {
            load_err(
                SKILL_MD,
                Some(&format!("{SKILL_TOML}{}", ACCOUNT.replacen(from, to, 1))),
            )
        };
        assert!(bad("contract = \"pool\"", "contract = \"oracle\"").contains("oracle"));
        assert!(bad(") view returns", ") returns").contains("view"));
        assert!(bad("args = [\"$self\"]", "args = []").contains("1 arguments"));
        assert!(bad("healthFactor = \"18\"", "health = \"18\"").contains("health"));
        assert!(bad("\"18\"", "\"eighteen\"").contains("decimals"));
        assert!(
            bad(
                "show = { healthFactor = \"18\", collateral = \"8 USD\" }",
                "show = {}"
            )
            .contains("no output")
        );
        assert!(bad("uint256 healthFactor)", "address healthFactor)").contains("not a uint"));
        assert!(bad("\"8 USD\"", "\"8 U\\u001bSD\"").contains("control"));
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
        // A contract is pinned or named by the user, never both and never neither.
        let pool_address = "address = { 11155111 = \"0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951\", 1 = \"0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2\" }";
        assert!(
            bad(pool_address, "address_arg = \"safe\"")
                .contains("only a pinned contract may be approved")
        );
        assert!(
            bad(
                pool_address,
                &format!("{pool_address}\naddress_arg = \"safe\"")
            )
            .contains("not both")
        );
        // `signed_calls` lets raw bytes through, so it needs the user-named kind of contract.
        assert!(
            bad(
                "functions = [\"function supply(",
                "signed_calls = [\"supply\"]\nfunctions = [\"function supply("
            )
            .contains("only for a contract at an address the user names")
        );
        assert!(bad(pool_address, "").contains("needs an `address` or an `address_arg`"));
        // `amounts` must name a listed function, a uint parameter, and an address parameter
        // holding the token.
        let amounts = |decl: &str| {
            bad(
                "label = \"Aave Pool\"",
                &format!("label = \"Aave Pool\"\namounts = {{ {decl} }}"),
            )
        };
        assert!(amounts("borrow = { amount = \"asset\" }").contains("borrow"));
        assert!(amounts("supply = { amount = \"nope\" }").contains("nope"));
        // `self_only` names a listed function's address parameter.
        let self_only = |decl: &str| {
            bad(
                "label = \"Aave Pool\"",
                &format!("label = \"Aave Pool\"\nself_only = {{ {decl} }}"),
            )
        };
        assert!(self_only("borrow = [\"onBehalfOf\"]").contains("borrow"));
        assert!(self_only("supply = [\"amount\"]").contains("not an address parameter"));
        assert!(self_only("supply = [\"payee\"]").contains("payee"));
        // Or a token id, for a function whose token is implied.
        let root = tempfile::tempdir().unwrap();
        let by_id = SKILL_TOML.replacen(
            "label = \"Aave Pool\"",
            "label = \"Aave Pool\"\namounts = { supply = { amount = \"ausdc\" } }",
            1,
        );
        let dir = folder(root.path(), "demo", SKILL_MD, Some(&by_id));
        assert!(load(&dir).is_ok());
        assert!(amounts("supply = { amount = \"referralCode\" }").contains("address"));
        assert!(amounts("supply = { asset = \"onBehalfOf\" }").contains("uint"));
        // Functions that would get around the plan checker's approval and recipient rules.
        let supply =
            "function supply(address asset,uint256 amount,address onBehalfOf,uint16 referralCode)";
        for sig in [
            "function approve(address spender,uint256 amount)",
            "function increaseAllowance(address spender,uint256 added)",
            "function permit(address owner,address spender,uint256 value,uint256 deadline,uint8 v,bytes32 r,bytes32 s)",
            "function transfer(address to,uint256 amount)",
            "function transferFrom(address from,address to,uint256 amount)",
            "function setApprovalForAll(address operator,bool approved)",
            "function multicall(bytes[] data)",
            "function execute(address target,bytes data)",
            "function batch((address,bytes)[] calls)",
        ] {
            let error = bad(supply, sig);
            assert!(error.contains("not allowed"), "{sig}: {error}");
        }
        for sig in [
            "function approveDelegation(address delegatee,uint256 amount)",
            "function delegationWithSig(address delegator,address delegatee,uint256 value,uint256 deadline,uint8 v,bytes32 r,bytes32 s)",
            "function increaseApproval(address spender,uint256 addedValue)",
            "function decreaseApproval(address spender,uint256 subtractedValue)",
            "function authorizeOperator(address operator)",
        ] {
            let error = bad(supply, sig);
            assert!(error.contains("not allowed"), "{sig}: {error}");
        }
        // Everything from the manifest that reaches the consent screen or the review is one line.
        assert!(bad("label = \"Aave Pool\"", "label = \"Aave\\nStep 9\"").contains("control"));
        assert!(bad("symbol = \"USDC\"", "symbol = \"US\\u001b[2JDC\"").contains("control"));
        assert!(bad("version = \"0.1.0\"", "version = \"0.1\\r0\"").contains("control"));
    }
}
