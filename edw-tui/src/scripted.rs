//! A deterministic stand-in for the LLM, for tests and end-to-end UI runs.
//!
//! Selected with `EDW_TUI_MODEL=scripted`. It maps a few keywords onto tool calls, so the UI,
//! the Rig loop, the confirmation hook and the real `edw` binary can all be exercised without
//! Ollama and without model nondeterminism.

use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use rig_agent::completion::{
    CompletionError, CompletionModel, CompletionRequest, CompletionResponse, Usage,
};
use rig_agent::streaming::StreamingCompletionResponse;
use rig_core::message::{
    AssistantContent, Message, ToolCall, ToolFunction, ToolResultContent, UserContent,
};
use serde_json::{Value, json};

#[derive(Clone, Default)]
pub struct ScriptedModel {
    calls: Arc<AtomicUsize>,
}

/// What the script does with one user message.
#[derive(Clone, Debug, PartialEq)]
pub enum Script {
    Call(&'static str, Value),
    /// Several tools in order, one per model turn (e.g. `load_skill`, then the skill's tool).
    Calls(Vec<(&'static str, Value)>),
    Say(String),
}

/// The call to make after `made` tool calls for this message, or `None` to answer.
pub fn next_call(script: &Script, made: usize) -> Option<(&'static str, Value)> {
    match script {
        Script::Call(name, args) if made == 0 => Some((name, args.clone())),
        Script::Calls(calls) => calls.get(made).cloned(),
        _ => None,
    }
}

/// The stablecoin a skill request names; USDC when it names none.
fn stablecoin(text: &str) -> &'static str {
    let words: Vec<String> = text
        .split(|c: char| !c.is_alphanumeric())
        .map(str::to_uppercase)
        .collect();
    ["USDC", "USDT", "DAI"]
        .into_iter()
        .find(|t| words.iter().any(|w| w == t))
        .unwrap_or("USDC")
}

/// The first address in a prompt: a `0x` + 40-hex word, or the `ADDR_n` alias the harness puts
/// in its place before the model sees the message (it reveals the alias again in tool arguments).
fn address_in(prompt: &str) -> Option<String> {
    prompt
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '_'))
        .find(|w| {
            let hex = w.len() == 42
                && w.starts_with("0x")
                && w[2..].chars().all(|c| c.is_ascii_hexdigit());
            let alias = w
                .strip_prefix("ADDR_")
                .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()));
            hex || alias
        })
        .map(str::to_owned)
}

/// The address right after the word `safe` (`safe 0x…`, `safe at ADDR_1`): `is it safe to send 5
/// USDC to 0x…` is not a Safe request.
fn safe_address_in(prompt: &str) -> Option<String> {
    let words: Vec<&str> = prompt.split_whitespace().collect();
    words.iter().enumerate().find_map(|(i, w)| {
        if !w
            .trim_matches(|c: char| !c.is_alphanumeric())
            .eq_ignore_ascii_case("safe")
        {
            return None;
        }
        let rest = &words[i + 1..];
        let next = if rest.first().is_some_and(|w| w.eq_ignore_ascii_case("at")) {
            rest.get(1)
        } else {
            rest.first()
        };
        address_in(next?)
    })
}

/// Safe requests: `what is waiting for signatures on safe 0x…`, `who controls safe 0x…`,
/// `what did safe 0x… do recently on gnosis`.
fn safe_script(prompt: &str, has: &dyn Fn(&str) -> bool) -> Option<Script> {
    if !has("safe") {
        return None;
    }
    let mut args = json!({"address": safe_address_in(prompt)?});
    if has("gnosis") {
        args["chain"] = json!("gnosis");
    }
    let asks_nonce = has("nonce");
    if (has("approve") || has("execute")) && asks_nonce {
        // Look at what waits first, then act on the one asked for: `approve nonce 1445 on safe 0x…`.
        let nonce = prompt
            .split_whitespace()
            .skip_while(|w| !w.eq_ignore_ascii_case("nonce"))
            .nth(1)
            .and_then(|w| {
                w.trim_matches(|c: char| !c.is_ascii_digit())
                    .parse::<u64>()
                    .ok()
            });
        let mut act = json!({"address": args["address"]});
        // `nonce <n>` is required for a write; without a number it is not a request to send.
        act["nonce"] = json!(nonce?);
        let tool = if has("execute") {
            "safe_execute"
        } else {
            "safe_approve_hash"
        };
        return Some(Script::Calls(vec![
            ("load_skill", json!({"name": "safe-multisig"})),
            ("safe_queue", args),
            (tool, act),
        ]));
    }
    let tool = if has("waiting")
        || has("pending")
        || has("queue")
        || has("sign")
        || has("signature")
        || has("signatures")
    {
        "safe_queue"
    } else if has("controls") || has("owners") || has("threshold") || has("signers") {
        "safe_info"
    } else {
        "safe_activity"
    };
    Some(Script::Calls(vec![
        ("load_skill", json!({"name": "safe-multisig"})),
        (tool, args),
    ]))
}

/// Skill requests: `what does aave pay`, `put <amount> <token> on aave`, `withdraw all my
/// <token> from aave`, `best <token> lending rates on <chain>`.
fn skill_script(prompt: &str, text: &str, has: &dyn Fn(&str) -> bool) -> Option<Script> {
    if let Some(safe) = safe_script(prompt, has) {
        return Some(safe);
    }
    let aave = ("load_skill", json!({"name": "aave-v3-lend"}));
    if has("aave") {
        let token = stablecoin(text);
        if has("withdraw") {
            let amount = if has("all") {
                "all".to_owned()
            } else {
                first_number(prompt).unwrap_or_else(|| "all".into())
            };
            return Some(Script::Calls(vec![
                aave,
                ("aave_withdraw", json!({"token": token, "amount": amount})),
            ]));
        }
        if has("put") || has("supply") || has("deposit") || has("lend") {
            let amount = first_number(prompt)?;
            return Some(Script::Calls(vec![
                aave,
                ("aave_supply", json!({"token": token, "amount": amount})),
            ]));
        }
        return Some(Script::Calls(vec![aave, ("aave_markets", json!({}))]));
    }
    if (has("best") || has("top")) && (has("rates") || has("yields") || has("pools")) {
        let mut args = json!({"limit": 3});
        if has("lending") || has("lend") {
            args["kind"] = json!("lend");
        }
        let words: Vec<&str> = prompt.split_whitespace().collect();
        if let Some(i) = words.iter().position(|w| w.eq_ignore_ascii_case("on"))
            && let Some(chain) = words.get(i + 1)
        {
            args["chain"] = json!(chain.trim_matches(|c: char| !c.is_alphanumeric()));
        }
        let token = stablecoin(text);
        if text.to_uppercase().contains(token) {
            args["symbol"] = json!(token);
        }
        return Some(Script::Calls(vec![
            ("load_skill", json!({"name": "defi-data"})),
            ("top_yields", args),
        ]));
    }
    None
}

fn usd(amount: f64) -> String {
    match amount {
        a if a >= 1e9 => format!("${:.1}B", a / 1e9),
        a if a >= 1e6 => format!("${:.1}M", a / 1e6),
        a if a >= 1e3 => format!("${:.1}K", a / 1e3),
        a => format!("${a:.0}"),
    }
}

/// The reply after a skill tool, from its result (`{"command","exit_code","output"}`), the way
/// a model would put it; `None` for other tools, which keep the plain "Done".
pub fn summary(tool: &str, result: &str) -> Option<String> {
    let result: Value = serde_json::from_str(result).ok()?;
    let output = result.get("output")?.as_str()?;
    match tool {
        "top_yields" => {
            let value: Value = serde_json::from_str(output).ok()?;
            let rows: Vec<String> = value["rows"]
                .as_array()?
                .iter()
                .map(|r| {
                    format!(
                        "{} {} {:.2}% (TVL {})",
                        r["project"].as_str().unwrap_or("?"),
                        r["symbol"].as_str().unwrap_or("?"),
                        r["apy_base"].as_f64().unwrap_or(0.0),
                        usd(r["tvl_usd"].as_f64().unwrap_or(0.0))
                    )
                })
                .collect();
            let chain = value["chain"]["name"].as_str().unwrap_or("this chain");
            Some(format!(
                "Best on {chain} (DefiLlama, past APY): {}.",
                rows.join(" · ")
            ))
        }
        "aave_markets" => {
            let value: Value = serde_json::from_str(output).ok()?;
            let markets = value["markets"].as_array()?;
            let rates: Vec<String> = markets
                .iter()
                .map(|m| {
                    format!(
                        "{} {:.2}%",
                        m["token"].as_str().unwrap_or("?"),
                        m["supply_apy_percent"].as_f64().unwrap_or(0.0)
                    )
                })
                .collect();
            let supplied: Vec<String> = markets
                .iter()
                .filter(|m| m["you_supplied"].as_str().is_some_and(|s| s != "0"))
                .map(|m| {
                    format!(
                        "{} {}",
                        m["you_supplied"].as_str().unwrap_or("0"),
                        m["token"].as_str().unwrap_or("?")
                    )
                })
                .collect();
            let held = if supplied.is_empty() {
                "You have nothing supplied yet.".to_owned()
            } else {
                format!("You have supplied {}.", supplied.join(", "))
            };
            Some(format!("Aave v3 pays now: {}. {held}", rates.join(" · ")))
        }
        "safe_info" => {
            let v: Value = serde_json::from_str(output).ok()?;
            Some(format!(
                "That Safe on {}: {} (v{}); {}. {}",
                v["chain"].as_str()?,
                v["rule"].as_str()?,
                v["version"].as_str().unwrap_or("?"),
                v["onchain_check"]
                    .as_str()
                    .unwrap_or("not checked on chain"),
                v["warning"].as_str().unwrap_or("No modules are enabled.")
            ))
        }
        "safe_queue" => {
            let v: Value = serde_json::from_str(output).ok()?;
            let rows = v["transactions"].as_array()?;
            if rows.is_empty() {
                return Some("Nothing is waiting for signatures on that Safe.".into());
            }
            let lines: Vec<String> = rows
                .iter()
                .map(|r| {
                    let warn = r["warnings"].as_array().map_or(String::new(), |w| {
                        w.iter()
                            .filter_map(Value::as_str)
                            .map(|w| format!(" ⚠ {w}."))
                            .collect()
                    });
                    format!(
                        "#{} {} ({} signed){warn}",
                        r["nonce"],
                        r["summary"].as_str().unwrap_or("?"),
                        r["signatures"].as_str().unwrap_or("?")
                    )
                })
                .collect();
            let approved: Vec<String> = rows
                .iter()
                .filter(|r| r["you_approved_on_chain"] == true)
                .map(|r| format!("#{}", r["nonce"]))
                .collect();
            let mine = if approved.is_empty() {
                String::new()
            } else {
                format!(" You approved {} on chain.", approved.join(", "))
            };
            Some(format!(
                "{} waiting ({}): {}{mine}",
                rows.len(),
                v["rule"].as_str()?,
                lines.join(" | ")
            ))
        }
        "safe_activity" => {
            let v: Value = serde_json::from_str(output).ok()?;
            let lines: Vec<String> = v["transactions"]
                .as_array()?
                .iter()
                .map(|r| format!("#{} {}", r["nonce"], r["summary"].as_str().unwrap_or("?")))
                .collect();
            Some(format!("Recently executed: {}", lines.join(" | ")))
        }
        "safe_execute" => Some(if output.contains("succeeded") {
            "Executed: the Safe ran the transaction and its nonce moved on.".to_owned()
        } else {
            format!("Not executed: {output}")
        }),
        "safe_approve_hash" => Some(if output.contains("succeeded") {
            "Approved on chain: the Safe now counts your approval for that transaction. It still needs the other owners, and someone must execute it in the Safe app.".to_owned()
        } else {
            format!("Not approved: {output}")
        }),
        "aave_supply" | "aave_withdraw" => Some(if output.contains("succeeded") {
            "Done: the transactions were sent and all succeeded.".to_owned()
        } else {
            format!(
                "It did not go through: {}",
                output.lines().next().unwrap_or("")
            )
        }),
        _ => None,
    }
}

fn first_number(prompt: &str) -> Option<String> {
    prompt
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| !c.is_ascii_digit() && c != '.'))
        .find(|w| !w.is_empty() && w.parse::<f64>().is_ok())
        .map(str::to_owned)
}

pub fn script(prompt: &str) -> Script {
    let text = prompt.to_lowercase();
    let has = |word: &str| {
        text.split(|c: char| !c.is_alphanumeric())
            .any(|w| w == word)
    };
    let named = || {
        let words: Vec<&str> = prompt.split_whitespace().collect();
        words
            .iter()
            .position(|w| w.eq_ignore_ascii_case("named"))
            .and_then(|i| words.get(i + 1))
            .map(|w| w.to_string())
    };

    if let Some(skill) = skill_script(prompt, &text, &has) {
        skill
    } else if has("shield") {
        Script::Say("edw cannot shield yet, so there is nothing I can run for that.".into())
    } else if has("transfer") || has("send") {
        // "send <amount> <token> to <recipient>"
        let words: Vec<&str> = prompt.split_whitespace().collect();
        let at = words.iter().position(|w| w.eq_ignore_ascii_case("to"));
        match (
            at,
            words.iter().position(|w| w.eq_ignore_ascii_case("send")),
        ) {
            (Some(to), Some(send)) if to == send + 3 && to + 1 < words.len() => Script::Call(
                "transfer",
                json!({"to": words[to + 1], "amount": words[send + 1], "token": words[send + 2]}),
            ),
            _ => Script::Say("Say it as: send <amount> <token> to <0x address>.".into()),
        }
    } else if has("swap") {
        // "swap <amount> <token> for|to|into <token>"
        let words: Vec<&str> = prompt.split_whitespace().collect();
        match words.iter().position(|w| w.eq_ignore_ascii_case("swap")) {
            Some(at) if words.len() > at + 4 => Script::Call(
                "swap",
                json!({"from_token": words[at + 2], "to_token": words[at + 4], "amount": words[at + 1], "amount_side": "input"}),
            ),
            _ => Script::Say("Say it as: swap <amount> <token> for <token>.".into()),
        }
    } else if has("use") || has("switch") {
        // "use bob", "switch to profile 1/0": the last word names the profile.
        let profile = prompt.split_whitespace().last().unwrap_or_default();
        Script::Call("use_profile", json!({ "profile": profile }))
    } else if has("address") || has("addresses") {
        Script::Call("profile_addresses", json!({}))
    } else if has("balance") {
        Script::Call("balance", json!({}))
    } else if has("unlock") {
        let network = if has("mainnet") {
            "mainnet"
        } else if has("local") {
            "local"
        } else {
            "sepolia"
        };
        Script::Call("unlock", json!({ "network": network }))
    } else if has("lock") {
        Script::Call("lock", json!({}))
    } else if has("add") && has("profile") {
        Script::Call(
            "add_profile",
            named().map_or(json!({}), |name| json!({ "name": name })),
        )
    } else if (has("create") || has("new")) && (has("profile") || has("seed") || has("mnemonic")) {
        Script::Call(
            "new_mnemonic",
            named().map_or(json!({}), |name| json!({ "name": name })),
        )
    } else if has("profiles") || has("profile") {
        Script::Call("list_profiles", json!({}))
    } else if has("network") || has("networks") {
        Script::Call("list_networks", json!({}))
    } else if has("status") {
        Script::Call("wallet_status", json!({}))
    } else {
        Script::Say(
            "I can unlock or lock the wallet, and list, create, add or rename profiles.".into(),
        )
    }
}

fn response(choice: AssistantContent) -> CompletionResponse {
    CompletionResponse::new(vec![choice], Usage::new(), "scripted")
}

impl CompletionModel for ScriptedModel {
    async fn completion(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, CompletionError> {
        // The user's message this turn answers, and how many tools were called since it.
        let history = &request.chat_history;
        let Some(at) = history.iter().rposition(|m| {
            matches!(m, Message::User { content }
                if content.iter().any(|part| matches!(part, UserContent::Text(_))))
        }) else {
            return Ok(response(AssistantContent::text(
                "(scripted model: no user message)",
            )));
        };
        let Message::User { content } = &history[at] else {
            unreachable!("matched above")
        };
        let prompt: String = content
            .iter()
            .filter_map(|part| match part {
                UserContent::Text(text) => Some(text.text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join(" ");
        let made = history[at + 1..]
            .iter()
            .map(|m| match m {
                Message::Assistant { content, .. } => content
                    .iter()
                    .filter(|part| matches!(part, AssistantContent::ToolCall(_)))
                    .count(),
                _ => 0,
            })
            .sum();
        let plan = script(&prompt);
        Ok(response(match (next_call(&plan, made), plan) {
            (Some((name, args)), _) => {
                let id = format!("scripted-{}", self.calls.fetch_add(1, Ordering::Relaxed));
                AssistantContent::ToolCall(ToolCall::from_wire(
                    id,
                    ToolFunction::new(name.to_owned(), args),
                ))
            }
            (None, Script::Say(text)) if made == 0 => AssistantContent::text(text),
            (None, _) => {
                // The last tool called and its result, for a skill's summing-up.
                let last_tool = history[at + 1..].iter().rev().find_map(|m| match m {
                    Message::Assistant { content, .. } => {
                        content.iter().find_map(|part| match part {
                            AssistantContent::ToolCall(call) => Some(call.function.name.clone()),
                            _ => None,
                        })
                    }
                    _ => None,
                });
                let last_result = history[at + 1..].iter().rev().find_map(|m| match m {
                    Message::User { content } => content.iter().find_map(|part| match part {
                        UserContent::ToolResult(result) => {
                            result.content.iter().find_map(|c| match c {
                                ToolResultContent::Text(text) => Some(text.text.clone()),
                                _ => None,
                            })
                        }
                        _ => None,
                    }),
                    _ => None,
                });
                let reply = last_tool
                    .zip(last_result)
                    .and_then(|(tool, result)| summary(&tool, &result));
                AssistantContent::text(reply.unwrap_or_else(|| {
                    "Done. The command and its output are in the log.".to_owned()
                }))
            }
        }))
    }

    async fn stream(
        &self,
        _request: CompletionRequest,
    ) -> Result<StreamingCompletionResponse, CompletionError> {
        Err(CompletionError::ResponseError(
            "the scripted model does not stream".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Skill requests are a short sequence: load the skill, then its tool, one per model turn.
    #[test]
    fn scripts_skill_requests_as_a_sequence_of_calls() {
        let aave = ("load_skill", json!({"name": "aave-v3-lend"}));
        assert_eq!(
            script("what does Aave pay on stablecoins?"),
            Script::Calls(vec![aave.clone(), ("aave_markets", json!({}))])
        );
        assert_eq!(
            script("put 100 USDC on aave"),
            Script::Calls(vec![
                aave.clone(),
                ("aave_supply", json!({"token": "USDC", "amount": "100"}))
            ])
        );
        assert_eq!(
            script("withdraw all my USDC from Aave"),
            Script::Calls(vec![
                aave,
                ("aave_withdraw", json!({"token": "USDC", "amount": "all"}))
            ])
        );
        assert_eq!(
            script("what are the best USDC lending rates on Ethereum?"),
            Script::Calls(vec![
                ("load_skill", json!({"name": "defi-data"})),
                (
                    "top_yields",
                    json!({"chain": "Ethereum", "kind": "lend", "symbol": "USDC", "limit": 3})
                )
            ])
        );
    }

    /// After a skill tool the stand-in answers like a model would: the numbers, in a sentence.
    #[test]
    fn skill_results_are_summed_up_in_the_reply() {
        let result = |output: Value| {
            json!({"command": "skill x", "exit_code": 0, "output": output.to_string()}).to_string()
        };
        let yields = result(json!({
            "source": "DefiLlama yields (yields.llama.fi)",
            "chain": {"name": "Ethereum", "chain_id": 1},
            "rows": [
                {"project": "aave-v3", "symbol": "USDC", "apy_base": 3.70, "tvl_usd": 152_297_361},
                {"project": "compound-v3", "symbol": "USDC", "apy_base": 3.1, "tvl_usd": 9_500_000},
            ]
        }));
        assert_eq!(
            summary("top_yields", &yields).unwrap(),
            "Best on Ethereum (DefiLlama, past APY): aave-v3 USDC 3.70% (TVL $152.3M) · compound-v3 USDC 3.10% (TVL $9.5M)."
        );
        let markets = result(json!({"markets": [
            {"token": "USDC", "supply_apy_percent": 3.702, "you_supplied": "0"},
            {"token": "DAI", "supply_apy_percent": 4.01, "you_supplied": "12.5"},
        ]}));
        assert_eq!(
            summary("aave_markets", &markets).unwrap(),
            "Aave v3 pays now: USDC 3.70% · DAI 4.01%. You have supplied 12.5 DAI."
        );
        let sent = json!({"command": "skill aave", "exit_code": 0,
            "output": "Sent 2 transactions, all succeeded:\n…"})
        .to_string();
        assert_eq!(
            summary("aave_supply", &sent).unwrap(),
            "Done: the transactions were sent and all succeeded."
        );
        assert!(
            summary("balance", &sent).is_none(),
            "other tools keep the plain reply"
        );
    }

    #[test]
    fn scripts_safe_requests_by_what_is_asked() {
        let safe = "0xA03be496e67Ec29bC62F01a428683D7F9c204930";
        let load = ("load_skill", json!({"name": "safe-multisig"}));
        let calls =
            |tool: &'static str, args: Value| Script::Calls(vec![load.clone(), (tool, args)]);
        assert_eq!(
            script(&format!("what is waiting for signatures on safe {safe}?")),
            calls("safe_queue", json!({"address": safe}))
        );
        assert_eq!(
            script(&format!("who controls safe {safe}?")),
            calls("safe_info", json!({"address": safe}))
        );
        assert_eq!(
            script(&format!("what did safe {safe} do recently on gnosis")),
            calls("safe_activity", json!({"address": safe, "chain": "gnosis"}))
        );
        assert_eq!(
            script(&format!("approve nonce 1445 on safe {safe}")),
            Script::Calls(vec![
                load.clone(),
                ("safe_queue", json!({"address": safe})),
                ("safe_approve_hash", json!({"address": safe, "nonce": 1445})),
            ])
        );
        assert_eq!(
            script(&format!("execute nonce 1446 on safe {safe}")),
            Script::Calls(vec![
                load.clone(),
                ("safe_queue", json!({"address": safe})),
                ("safe_execute", json!({"address": safe, "nonce": 1446})),
            ])
        );
        // Words that merely contain "safe", or a write without a nonce, are not Safe requests.
        for prompt in [
            format!("is it safe to send 5 USDC to {safe}?"),
            format!("approve the router for 5 USDC, keep it safe {safe}"),
            format!("approve safe {safe}"),
            format!("execute safe {safe} now"),
        ] {
            assert!(
                !matches!(script(&prompt), Script::Calls(ref c) if c.iter().any(|(t, _)| matches!(*t, "safe_approve_hash" | "safe_execute"))),
                "{prompt}"
            );
        }
        // The harness hands the model an alias, not the address itself.
        assert_eq!(
            script("who controls safe ADDR_1?"),
            calls("safe_info", json!({"address": "ADDR_1"}))
        );
        // No address: nothing to look up, so it is not a Safe request.
        assert!(!matches!(script("what is a safe"), Script::Calls(_)));
    }

    #[test]
    fn safe_results_are_summed_up_in_the_reply() {
        let result = |output: Value| {
            json!({"command": "skill x", "exit_code": 0, "output": output.to_string()}).to_string()
        };
        let info = result(json!({
            "chain": "Ethereum", "rule": "4 of 11 owners must sign", "version": "1.3.0",
            "onchain_check": "owners and threshold match the chain",
        }));
        assert_eq!(
            summary("safe_info", &info).unwrap(),
            "That Safe on Ethereum: 4 of 11 owners must sign (v1.3.0); owners and threshold match the chain. No modules are enabled."
        );
        let queue = result(json!({
            "rule": "4 of 11 owners must sign",
            "transactions": [
                {"nonce": 1445, "summary": "Sends 1 COW to 0x6C9F…5711", "signatures": "1 of 4", "warnings": []},
                {"nonce": 1446, "summary": "Pays 5 COW to 2 recipients", "signatures": "4 of 4",
                 "warnings": ["changes who controls the Safe"]},
            ]
        }));
        assert_eq!(
            summary("safe_queue", &queue).unwrap(),
            "2 waiting (4 of 11 owners must sign): #1445 Sends 1 COW to 0x6C9F…5711 (1 of 4 signed) | #1446 Pays 5 COW to 2 recipients (4 of 4 signed) ⚠ changes who controls the Safe."
        );
        let empty = result(json!({"rule": "1 of 1 owners must sign", "transactions": []}));
        assert_eq!(
            summary("safe_queue", &empty).unwrap(),
            "Nothing is waiting for signatures on that Safe."
        );
    }

    #[test]
    fn the_next_call_is_the_first_one_not_made_yet() {
        let calls = Script::Calls(vec![
            ("load_skill", json!({"name": "a"})),
            ("aave_markets", json!({})),
        ]);
        assert_eq!(next_call(&calls, 0).unwrap().0, "load_skill");
        assert_eq!(next_call(&calls, 1).unwrap().0, "aave_markets");
        assert!(next_call(&calls, 2).is_none(), "then it answers");
        let one = Script::Call("balance", json!({}));
        assert_eq!(next_call(&one, 0).unwrap().0, "balance");
        assert!(next_call(&one, 1).is_none());
    }

    #[test]
    fn scripts_intents() {
        assert_eq!(
            script("unlock sepolia please"),
            Script::Call("unlock", json!({"network": "sepolia"}))
        );
        assert_eq!(
            script("Unlock mainnet"),
            Script::Call("unlock", json!({"network": "mainnet"}))
        );
        assert_eq!(script("lock it"), Script::Call("lock", json!({})));
        assert_eq!(
            script("show my profiles"),
            Script::Call("list_profiles", json!({}))
        );
        assert_eq!(
            script("add a profile named bob"),
            Script::Call("add_profile", json!({"name": "bob"}))
        );
        assert_eq!(
            script("send 0.1 ETH to 0x000000000000000000000000000000000000bEEF"),
            Script::Call(
                "transfer",
                json!({"to": "0x000000000000000000000000000000000000bEEF", "amount": "0.1", "token": "ETH"})
            )
        );
        assert_eq!(
            script("what is my balance"),
            Script::Call("balance", json!({}))
        );
        assert!(matches!(script("shield 1 ETH"), Script::Say(_)));
        assert_eq!(
            script("swap 0.01 ETH for USDC"),
            Script::Call(
                "swap",
                json!({"from_token": "ETH", "to_token": "USDC", "amount": "0.01", "amount_side": "input"})
            )
        );
    }
}
