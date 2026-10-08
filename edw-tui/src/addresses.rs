//! The model never retypes a 0x address.
//!
//! Every full address on its way to the model (the user's words, tool results) is swapped for a
//! short alias such as `ADDR_1`, and aliases on their way back (tool arguments, replies) are
//! swapped for the address again. Small models lose count inside long hex strings: qwen3:8b
//! writing `0x000…000bEEF` stalls inside the run of zeros and Ollama aborts the reply. A model
//! that never retypes an address also cannot mistype one. The review modal is built from the
//! real address, so the user always checks what will actually be sent.
//!
//! `EDW_TUI_ADDRESS_ALIASES=0` turns it off (e.g. to evaluate a model on raw addresses).

use std::sync::{Arc, LazyLock, Mutex};

use regex::Regex;
use serde_json::Value;

static ADDRESS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b0x[0-9a-fA-F]{40}\b").expect("valid regex"));
static ALIAS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\bADDR_(\d+)\b").expect("valid regex"));

static ALIAS_UPPER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\bADDR_(\d+)\b").expect("valid regex"));

pub const PREFIX: &str = "ADDR_";

#[derive(Clone, Debug)]
pub struct AddressBook {
    seen: Arc<Mutex<Vec<String>>>,
    enabled: bool,
}

impl Default for AddressBook {
    fn default() -> Self {
        Self::new(true)
    }
}

impl AddressBook {
    pub fn new(enabled: bool) -> Self {
        Self {
            seen: Arc::new(Mutex::new(Vec::new())),
            enabled,
        }
    }

    pub fn from_env() -> Self {
        Self::new(std::env::var("EDW_TUI_ADDRESS_ALIASES").map_or(true, |v| v != "0"))
    }

    /// Replaces every 0x address with its alias, assigning new aliases in order of appearance.
    /// The same address (in any letter case) always gets the same alias.
    pub fn hide(&self, text: &str) -> String {
        if !self.enabled {
            return text.to_owned();
        }
        let mut seen = self.seen.lock().expect("not poisoned");
        ADDRESS
            .replace_all(text, |caps: &regex::Captures| {
                let address = &caps[0];
                let index = match seen.iter().position(|a| a.eq_ignore_ascii_case(address)) {
                    Some(index) => index,
                    None => {
                        seen.push(address.to_owned());
                        seen.len() - 1
                    }
                };
                format!("{PREFIX}{}", index + 1)
            })
            .into_owned()
    }

    /// Replaces every known alias with its address; unknown aliases are left as written.
    pub fn reveal(&self, text: &str) -> String {
        self.reveal_with(&ALIAS, text)
    }

    /// Like [`Self::reveal`] but only the uppercase `ADDR_n` form: lowercase `addr_1` (an
    /// identifier in code) is left alone.
    pub fn reveal_uppercase(&self, text: &str) -> String {
        self.reveal_with(&ALIAS_UPPER, text)
    }

    fn reveal_with(&self, pattern: &Regex, text: &str) -> String {
        if !self.enabled {
            return text.to_owned();
        }
        let seen = self.seen.lock().expect("not poisoned");
        pattern
            .replace_all(text, |caps: &regex::Captures| {
                caps[1]
                    .parse::<usize>()
                    .ok()
                    .and_then(|n| n.checked_sub(1))
                    .and_then(|i| seen.get(i))
                    .cloned()
                    .unwrap_or_else(|| caps[0].to_owned())
            })
            .into_owned()
    }

    /// With aliases on, the model is never shown a raw address, so any raw address it writes is
    /// one it made up (or recalled from training). Returns the first such address.
    pub fn invented<'t>(&self, model_text: &'t str) -> Option<&'t str> {
        if !self.enabled {
            return None;
        }
        let seen = self.seen.lock().expect("not poisoned");
        ADDRESS
            .find_iter(model_text)
            .map(|m| m.as_str())
            .find(|address| !seen.iter().any(|a| a.eq_ignore_ascii_case(address)))
    }

    /// Flags every made-up address in a model reply, so the user never takes it for real.
    pub fn flag_invented(&self, model_text: &str) -> String {
        if !self.enabled {
            return model_text.to_owned();
        }
        let seen = self.seen.lock().expect("not poisoned").clone();
        ADDRESS
            .replace_all(model_text, |caps: &regex::Captures| {
                let address = &caps[0];
                if seen.iter().any(|a| a.eq_ignore_ascii_case(address)) {
                    address.to_owned()
                } else {
                    format!(
                        "{address} [not from any tool or message: the model made this address up]"
                    )
                }
            })
            .into_owned()
    }

    /// [`Self::reveal`] on every string inside a tool call's JSON arguments.
    pub fn reveal_json(&self, value: Value) -> Value {
        match value {
            Value::String(s) => Value::String(self.reveal(&s)),
            Value::Array(items) => {
                Value::Array(items.into_iter().map(|v| self.reveal_json(v)).collect())
            }
            Value::Object(map) => Value::Object(
                map.into_iter()
                    .map(|(k, v)| (k, self.reveal_json(v)))
                    .collect(),
            ),
            other => other,
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const BEEF: &str = "0x000000000000000000000000000000000000bEEF";
    const ALICE: &str = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

    #[test]
    fn reveal_uppercase_leaves_lowercase_aliases_alone() {
        let book = AddressBook::default();
        book.hide(BEEF);
        assert_eq!(
            book.reveal_uppercase("a = ADDR_1; b = addr_1"),
            format!("a = {BEEF}; b = addr_1")
        );
        assert_eq!(book.reveal("addr_1"), BEEF);
    }

    #[test]
    fn round_trips_addresses_through_aliases() {
        let book = AddressBook::default();
        let hidden = book.hide(&format!(
            "send 0.2ETH to {BEEF}, then 1 to {ALICE} and {}",
            BEEF.to_lowercase()
        ));
        assert_eq!(hidden, "send 0.2ETH to ADDR_1, then 1 to ADDR_2 and ADDR_1");
        assert_eq!(
            book.reveal("sent to ADDR_2 and addr_1"),
            format!("sent to {ALICE} and {BEEF}")
        );
        assert_eq!(book.reveal("ADDR_9 stays"), "ADDR_9 stays");
        assert_eq!(
            book.reveal_json(json!({"to": "ADDR_1", "amount": "0.2", "nested": ["ADDR_2"]})),
            json!({"to": BEEF, "amount": "0.2", "nested": [ALICE]})
        );
    }

    #[test]
    fn flags_addresses_the_model_made_up() {
        let book = AddressBook::default();
        book.hide(&format!("send to {ALICE}"));
        let reply = format!("Sent to ADDR_1. Bob's address is {BEEF}.");
        assert_eq!(book.invented(&reply), Some(BEEF));
        assert!(book.invented("Sent to ADDR_1.").is_none());
        let flagged = book.reveal(&book.flag_invented(&reply));
        assert!(
            flagged.starts_with(&format!("Sent to {ALICE}.")),
            "{flagged}"
        );
        assert!(
            flagged.contains(&format!("{BEEF} [not from any tool")),
            "{flagged}"
        );
        assert!(AddressBook::new(false).invented(BEEF).is_none());
    }

    #[test]
    fn leaves_hashes_and_short_hex_alone() {
        let book = AddressBook::default();
        let hash = "0xa9f07c6e3e30aacae51ac6a2ecf6e062dfae2efe8614f8103e8b4c49a04d7178";
        assert_eq!(
            book.hide(&format!("tx {hash} to 0x1234")),
            format!("tx {hash} to 0x1234")
        );
    }

    #[test]
    fn can_be_turned_off() {
        let book = AddressBook::new(false);
        assert_eq!(book.hide(BEEF), BEEF);
        assert_eq!(book.reveal("ADDR_1"), "ADDR_1");
    }
}
