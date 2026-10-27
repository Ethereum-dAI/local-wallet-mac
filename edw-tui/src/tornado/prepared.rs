//! Prepared shields: edw's `shield --prepare` answers, kept so that a retry reuses them.
//!
//! Preparing reserves notes in edw's wallet (it spends Tornado nonces), and preparing again
//! reserves different ones. So each answer is written to disk before anyone hears of it, is never
//! deleted, and is found again by what it was for: the same network, profile, token and amount.
//! Once a bundler accepted an unshield that ends with its calls, it is marked consumed and never
//! offered again: those deposits may be on chain.

use std::{
    fs,
    future::Future,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

use super::{PoolAmount, TailCalls, Token};

const KIND: &str = "edw/shield-prepared";
const PREFIX: &str = "shield-";

/// edw's `edw/shield-prepared` document, version 1.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Document {
    kind: String,
    version: u32,
    chain_id: u64,
    token: String,
    broadcast: bool,
    notes: Vec<Note>,
    calls: Vec<Call>,
    tail_calls: String,
}

/// A reserved note's public metadata; edw never puts its secret in the document.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Note {
    pub nonce: u64,
    pub pool: String,
    pub commitment: String,
    pub amount: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Call {
    target: String,
    data: String,
    value: String,
}

/// One stored preparation: what it was for, and edw's answer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreparedShield {
    pub id: String,
    pub network: String,
    pub profile: String,
    pub token: Token,
    pub amount: String,
    edw: Document,
    /// What shows a bundler accepted an unshield ending with these calls: its user operation, or
    /// the fresh address edw stored for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consumed: Option<String>,
}

impl PreparedShield {
    pub fn notes(&self) -> &[Note] {
        &self.edw.notes
    }

    /// The deposit calls, ready to append to an unshield's tail calls.
    pub fn tail_calls(&self) -> TailCalls {
        TailCalls(self.edw.tail_calls.clone())
    }

    /// What the model is told: the id and what was reserved, never the calls.
    pub fn summary(&self, reused: bool) -> Value {
        json!({
            "id": self.id,
            "reused": reused,
            "network": self.network,
            "token": self.token,
            "amount": self.amount,
            "notes": self.edw.notes,
            "broadcast": false,
        })
    }

    fn is_for(&self, amount: &PoolAmount, profile: &str) -> bool {
        self.consumed.is_none()
            && self.network == amount.network.to_string()
            && self.profile == profile
            && self.token == amount.token
            && self.amount == amount.amount
    }
}

pub struct Store {
    dir: PathBuf,
    /// One preparation at a time, so two calls for the same deposit cannot both reserve notes.
    busy: Mutex<()>,
}

impl Store {
    pub fn new(dir: PathBuf) -> Self {
        Self {
            dir,
            busy: Mutex::new(()),
        }
    }

    /// Beside edw's own data; edw only reads folders named after a network.
    pub fn in_data_dir(data_dir: &Path) -> Self {
        Self::new(data_dir.join("edw-tui").join("prepared-shields"))
    }

    /// The stored preparation for `amount` and `profile` that is not consumed, or else the one
    /// `prepare` gets from edw, saved before it is returned. `true` when it was stored already.
    /// `prepare`'s own error comes back as it is; the store's is a `String`.
    pub async fn reuse_or<F, Fut, E>(
        &self,
        amount: &PoolAmount,
        profile: &str,
        prepare: F,
    ) -> Result<(PreparedShield, bool), E>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<Value, E>>,
        E: From<String>,
    {
        let _one_at_a_time = self.busy.lock().await;
        if let Some(stored) = self
            .records()
            .into_iter()
            .find(|r| r.is_for(amount, profile))
        {
            return Ok((stored, true));
        }
        let document = prepare().await?;
        Ok((
            self.save(amount, profile, document).map_err(E::from)?,
            false,
        ))
    }

    /// Marks `id` consumed, `by` what shows it. A record consumed already keeps its first reason.
    pub async fn consume(&self, id: &str, by: &str) -> Result<PreparedShield, String> {
        let _one_at_a_time = self.busy.lock().await;
        let mut record = self.get(id)?;
        if record.consumed.is_none() {
            record.consumed = Some(by.to_owned());
            let text = serde_json::to_string_pretty(&record).expect("serializable");
            self.write(&record.id, &text)?;
        }
        Ok(record)
    }

    pub fn get(&self, id: &str) -> Result<PreparedShield, String> {
        let digits = id.strip_prefix(PREFIX).unwrap_or_default();
        if digits.len() != 10 || !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("`{id}` is not a prepared shield id"));
        }
        let path = self.dir.join(format!("{id}.json"));
        let text =
            fs::read_to_string(&path).map_err(|e| format!("no prepared shield {id} ({e})"))?;
        serde_json::from_str(&text).map_err(|e| format!("{} is unreadable: {e}", path.display()))
    }

    fn records(&self) -> Vec<PreparedShield> {
        let Ok(entries) = fs::read_dir(&self.dir) else {
            return Vec::new();
        };
        let mut names: Vec<String> = entries
            .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
            .filter(|name| name.starts_with(PREFIX) && name.ends_with(".json"))
            .collect();
        names.sort();
        names
            .iter()
            .filter_map(|name| fs::read_to_string(self.dir.join(name)).ok())
            .filter_map(|text| serde_json::from_str(&text).ok())
            .collect()
    }

    fn save(
        &self,
        amount: &PoolAmount,
        profile: &str,
        document: Value,
    ) -> Result<PreparedShield, String> {
        let text = document.to_string();
        let digest: String = Sha256::digest(text.as_bytes())[..5]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let expected = serde_json::from_value::<Document>(document)
            .ok()
            .filter(|d| {
                d.kind == KIND
                    && d.version == 1
                    && !d.broadcast
                    && d.chain_id == amount.network.network_id().0
                    && d.token.eq_ignore_ascii_case(amount.token.symbol())
                    && d.notes.len() == amount.notes.len()
                    && !d.tail_calls.is_empty()
            });
        let Some(edw) = expected else {
            // The notes are reserved all the same, so edw's answer is kept, not dropped.
            let kept = self.write(&format!("unreadable-{digest}"), &text)?;
            return Err(format!(
                "edw reserved notes, but its answer was not the {KIND} document expected; it is kept in {}",
                kept.display()
            ));
        };
        let record = PreparedShield {
            id: format!("{PREFIX}{digest}"),
            network: amount.network.to_string(),
            profile: profile.to_owned(),
            token: amount.token,
            amount: amount.amount.clone(),
            edw,
            consumed: None,
        };
        let text = serde_json::to_string_pretty(&record).expect("serializable");
        self.write(&record.id, &text)?;
        Ok(record)
    }

    /// Writes `<name>.json` whole or not at all, readable by this user only.
    fn write(&self, name: &str, text: &str) -> Result<PathBuf, String> {
        let fail = |e: std::io::Error| {
            format!(
                "cannot save the prepared shield in {}: {e}",
                self.dir.display()
            )
        };
        fs::create_dir_all(&self.dir).map_err(fail)?;
        fs::set_permissions(&self.dir, fs::Permissions::from_mode(0o700)).map_err(fail)?;
        let path = self.dir.join(format!("{name}.json"));
        let partial = self.dir.join(format!(".{name}.partial"));
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&partial)
            .map_err(fail)?;
        file.write_all(text.as_bytes())
            .and_then(|()| file.sync_all())
            .map_err(fail)?;
        fs::rename(&partial, &path).map_err(fail)?;
        fs::File::open(&self.dir)
            .and_then(|dir| dir.sync_all())
            .map_err(fail)?;
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use edw_core::network::NetworkPreset;

    use super::*;

    const DAI_200: &str = include_str!("../../tests/fixtures/shield_prepared_dai_200.json");
    const APPROVE_CALLDATA: &str = "0x095ea7b3";

    fn dai(amount: &str) -> PoolAmount {
        PoolAmount::new(NetworkPreset::Sepolia, Token::Dai, amount).unwrap()
    }

    /// Prepares like edw would, counting how often it is asked to.
    async fn prepare(
        store: &Store,
        amount: &PoolAmount,
        profile: &str,
        asked: &AtomicUsize,
    ) -> Result<(PreparedShield, bool), String> {
        store
            .reuse_or(amount, profile, || async {
                asked.fetch_add(1, Ordering::SeqCst);
                Ok(serde_json::from_str(DAI_200).unwrap())
            })
            .await
    }

    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[tokio::test]
    async fn a_preparation_is_saved_before_it_is_returned_and_reused_after_a_restart() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::in_data_dir(root.path());
        let asked = AtomicUsize::new(0);

        let (first, reused) = prepare(&store, &dai("200"), "0/0", &asked).await.unwrap();
        assert!(!reused);
        let path = store.dir.join(format!("{}.json", first.id));
        assert_eq!(mode(&path), 0o600);
        assert_eq!(mode(&store.dir), 0o700);
        assert_eq!(
            Store::in_data_dir(root.path()).get(&first.id).unwrap(),
            first
        );

        let reopened = Store::in_data_dir(root.path());
        let (again, reused) = prepare(&reopened, &dai("200"), "0/0", &asked)
            .await
            .unwrap();
        assert!(reused);
        assert_eq!(again.id, first.id);
        assert_eq!(
            asked.load(Ordering::SeqCst),
            1,
            "a retry must not prepare again"
        );
        assert_eq!(
            again.tail_calls(),
            TailCalls(document()["tail_calls"].as_str().unwrap().into())
        );
    }

    fn document() -> Value {
        serde_json::from_str(DAI_200).unwrap()
    }

    #[tokio::test]
    async fn another_amount_or_profile_is_another_preparation() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::in_data_dir(root.path());
        let asked = AtomicUsize::new(0);
        prepare(&store, &dai("200"), "0/0", &asked).await.unwrap();
        let (_, reused) = prepare(&store, &dai("200"), "0/1", &asked).await.unwrap();
        assert!(!reused);
        // The fixture is edw's answer for 200 DAI, so for 100 it is asked for and then refused.
        let refused = prepare(&store, &dai("100"), "0/0", &asked).await;
        assert!(refused.unwrap_err().contains("kept in"));
        assert_eq!(asked.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn the_model_sees_the_notes_but_no_calldata() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::in_data_dir(root.path());
        let (record, _) = prepare(&store, &dai("200"), "0/0", &AtomicUsize::new(0))
            .await
            .unwrap();
        let summary = record.summary(false).to_string();
        assert!(summary.contains(&record.id) && summary.contains("dai-100-11155111"));
        assert_eq!(record.summary(false)["notes"].as_array().unwrap().len(), 2);
        for call in document()["calls"].as_array().unwrap() {
            let data = call["data"].as_str().unwrap();
            assert!(!summary.contains(data), "{summary}");
        }
        assert!(!summary.contains(APPROVE_CALLDATA) && !summary.contains("tail_calls"));
    }

    #[tokio::test]
    async fn nothing_is_returned_when_the_record_cannot_be_saved() {
        let root = tempfile::tempdir().unwrap();
        let blocked = root.path().join("not-a-folder");
        fs::write(&blocked, "").unwrap();
        let store = Store::new(blocked.join("prepared"));
        let saved = prepare(&store, &dai("200"), "0/0", &AtomicUsize::new(0)).await;
        assert!(saved.unwrap_err().contains("cannot save"));
    }

    #[tokio::test]
    async fn an_unexpected_answer_is_kept_and_not_reused() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::in_data_dir(root.path());
        let mut broadcast = document();
        broadcast["broadcast"] = Value::Bool(true);
        for answer in [json!({"kind": "edw/error"}), broadcast] {
            let failed = store
                .reuse_or(&dai("200"), "0/0", || async { Ok::<_, String>(answer) })
                .await;
            assert!(failed.unwrap_err().contains("kept in"));
        }
        let kept = fs::read_dir(&store.dir)
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with("unreadable-")
            })
            .count();
        assert_eq!(kept, 2);
        let asked = AtomicUsize::new(0);
        prepare(&store, &dai("200"), "0/0", &asked).await.unwrap();
        assert_eq!(asked.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn a_consumed_preparation_is_never_reused_and_keeps_its_first_reason() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::in_data_dir(root.path());
        let asked = AtomicUsize::new(0);
        let (first, _) = prepare(&store, &dai("200"), "0/0", &asked).await.unwrap();
        store
            .consume(&first.id, "user operation 0xaa")
            .await
            .unwrap();
        let again = store
            .consume(&first.id, "user operation 0xbb")
            .await
            .unwrap();
        assert_eq!(again.consumed.as_deref(), Some("user operation 0xaa"));

        // edw reserves new notes for a new preparation, so its answer differs.
        let mut fresh = document();
        fresh["notes"][0]["commitment"] = json!(format!("0x{}", "11".repeat(32)));
        let (second, reused) = Store::in_data_dir(root.path())
            .reuse_or(&dai("200"), "0/0", || async {
                asked.fetch_add(1, Ordering::SeqCst);
                Ok::<_, String>(fresh)
            })
            .await
            .unwrap();
        assert!(!reused && second.id != first.id && second.consumed.is_none());
        assert_eq!(asked.load(Ordering::SeqCst), 2);
        let stored = Store::in_data_dir(root.path()).get(&first.id).unwrap();
        assert_eq!(stored.consumed.as_deref(), Some("user operation 0xaa"));

        let (third, reused) = prepare(&store, &dai("200"), "0/0", &asked).await.unwrap();
        assert!(
            reused && third.id == second.id,
            "the unconsumed one is reused"
        );
    }

    #[test]
    fn get_takes_only_an_id() {
        let store = Store::new(PathBuf::from("/nonexistent"));
        for id in ["../../etc/passwd", "shield-", "shield-zzzzzzzzzz", "x"] {
            assert!(
                store
                    .get(id)
                    .unwrap_err()
                    .contains("not a prepared shield id"),
                "{id}"
            );
        }
    }
}
