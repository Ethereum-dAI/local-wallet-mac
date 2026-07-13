use std::{
    collections::BTreeMap,
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rand::RngCore;
use serde_json::json;

pub(crate) const ADMIN_CHALLENGE_TTL_SECONDS: u64 = 60;
pub(crate) const ADMIN_CHALLENGE_TTL: Duration = Duration::from_secs(ADMIN_CHALLENGE_TTL_SECONDS);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AdminChallenge {
    pub id: String,
    pub nonce: String,
    pub action: String,
    pub owner_scope: String,
    pub chain_id: u64,
    pub key_ref: Option<String>,
    pub summary: String,
    pub expires_at: u64,
    deadline: Instant,
    pub used: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AdminChallengeRequest {
    pub action: String,
    pub owner_scope: String,
    pub chain_id: u64,
    pub key_ref: Option<String>,
    pub summary: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AdminAuthorization {
    pub admin_action_id: String,
    pub nonce: String,
}

#[derive(Default, Debug)]
pub(crate) struct AdminChallengeStore {
    challenges: Mutex<BTreeMap<String, AdminChallenge>>,
}

impl AdminChallengeStore {
    pub(crate) fn begin(&self, request: AdminChallengeRequest) -> AdminChallenge {
        let mut id_bytes = [0u8; 16];
        let mut nonce_bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut id_bytes);
        rand::thread_rng().fill_bytes(&mut nonce_bytes);
        let id = URL_SAFE_NO_PAD.encode(id_bytes);
        let nonce = URL_SAFE_NO_PAD.encode(nonce_bytes);
        let expires_at = now_unix_seconds() + ADMIN_CHALLENGE_TTL_SECONDS;
        let deadline = Instant::now() + ADMIN_CHALLENGE_TTL;
        let challenge = AdminChallenge {
            id,
            nonce,
            action: request.action,
            owner_scope: request.owner_scope,
            chain_id: request.chain_id,
            key_ref: request.key_ref,
            summary: request.summary,
            expires_at,
            deadline,
            used: false,
        };

        let mut challenges = self
            .challenges
            .lock()
            .expect("admin challenge mutex should not be poisoned");
        challenges.retain(|_, existing| {
            !(existing.action == challenge.action
                && existing.owner_scope == challenge.owner_scope
                && existing.chain_id == challenge.chain_id
                && existing.key_ref == challenge.key_ref)
                && Instant::now() < existing.deadline
                && !existing.used
        });
        challenges.insert(challenge.id.clone(), challenge.clone());
        challenge
    }

    pub(crate) fn consume(
        &self,
        authorization: &AdminAuthorization,
        expected_action: &str,
        expected_owner_scope: &str,
        expected_chain_id: u64,
        expected_key_ref: Option<&str>,
    ) -> Result<AdminChallenge, wallet_node_api::JsonRpcError> {
        let mut challenges = self
            .challenges
            .lock()
            .expect("admin challenge mutex should not be poisoned");
        let Some(challenge) = challenges.get_mut(&authorization.admin_action_id) else {
            return Err(admin_error("admin_challenge_missing"));
        };
        if challenge.used {
            return Err(admin_error("admin_challenge_used"));
        }
        if Instant::now() >= challenge.deadline {
            challenge.used = true;
            return Err(admin_error("admin_challenge_expired"));
        }
        if challenge.action != expected_action {
            return Err(admin_error("admin_challenge_action_mismatch"));
        }
        if challenge.owner_scope != expected_owner_scope {
            return Err(admin_error("admin_challenge_owner_scope_mismatch"));
        }
        if challenge.chain_id != expected_chain_id {
            return Err(admin_error("admin_challenge_chain_mismatch"));
        }
        if challenge.key_ref.as_deref() != expected_key_ref {
            return Err(admin_error("admin_challenge_key_mismatch"));
        }
        if challenge.nonce != authorization.nonce {
            return Err(admin_error("admin_challenge_nonce_mismatch"));
        }
        challenge.used = true;
        Ok(challenge.clone())
    }

    #[cfg(test)]
    fn force_monotonic_expire(&self, id: &str) {
        let mut challenges = self
            .challenges
            .lock()
            .expect("admin challenge mutex should not be poisoned");
        if let Some(challenge) = challenges.get_mut(id) {
            challenge.expires_at = now_unix_seconds().saturating_sub(1);
            challenge.deadline = Instant::now() - Duration::from_secs(1);
        }
    }
}

pub(crate) fn challenge_json(challenge: &AdminChallenge) -> serde_json::Value {
    json!({
        "adminActionId": challenge.id,
        "nonce": challenge.nonce,
        "action": challenge.action,
        "ownerScope": challenge.owner_scope,
        "chainId": challenge.chain_id,
        "keyRef": challenge.key_ref,
        "summary": challenge.summary,
        "expiresAt": challenge.expires_at
    })
}

pub(crate) fn admin_error(reason: &'static str) -> wallet_node_api::JsonRpcError {
    wallet_node_api::JsonRpcError {
        code: wallet_node_api::INVALID_REQUEST,
        message: format!("Invalid admin authorization: {reason}"),
        data: Some(json!({ "reason": reason })),
    }
}

fn now_unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(action: &str) -> AdminChallengeRequest {
        AdminChallengeRequest {
            action: action.to_string(),
            owner_scope: "default".to_string(),
            chain_id: 1,
            key_ref: Some("key".to_string()),
            summary: "summary".to_string(),
        }
    }

    #[test]
    fn challenge_is_single_use_and_action_scoped() {
        let store = AdminChallengeStore::default();
        let challenge = store.begin(request("rotate_bundler_eoa"));
        let auth = AdminAuthorization {
            admin_action_id: challenge.id.clone(),
            nonce: challenge.nonce.clone(),
        };

        assert!(store
            .consume(&auth, "rotate_bundler_eoa", "default", 1, Some("key"))
            .is_ok());
        let err = store
            .consume(&auth, "rotate_bundler_eoa", "default", 1, Some("key"))
            .unwrap_err();
        assert_eq!(err.data.unwrap()["reason"], "admin_challenge_used");
    }

    #[test]
    fn challenge_mismatch_is_rejected() {
        let store = AdminChallengeStore::default();
        let challenge = store.begin(request("rotate_bundler_eoa"));
        let auth = AdminAuthorization {
            admin_action_id: challenge.id,
            nonce: challenge.nonce,
        };

        let err = store
            .consume(&auth, "delete_bundler_eoa", "default", 1, Some("key"))
            .unwrap_err();

        assert_eq!(
            err.data.unwrap()["reason"],
            "admin_challenge_action_mismatch"
        );
    }

    #[test]
    fn owner_chain_key_nonce_and_expiry_mismatches_are_rejected() {
        let store = AdminChallengeStore::default();

        let owner = store.begin(request("rotate_bundler_eoa"));
        let err = store
            .consume(
                &AdminAuthorization {
                    admin_action_id: owner.id,
                    nonce: owner.nonce,
                },
                "rotate_bundler_eoa",
                "profile2",
                1,
                Some("key"),
            )
            .unwrap_err();
        assert_eq!(
            err.data.unwrap()["reason"],
            "admin_challenge_owner_scope_mismatch"
        );

        let chain = store.begin(request("rotate_bundler_eoa"));
        let err = store
            .consume(
                &AdminAuthorization {
                    admin_action_id: chain.id,
                    nonce: chain.nonce,
                },
                "rotate_bundler_eoa",
                "default",
                11155111,
                Some("key"),
            )
            .unwrap_err();
        assert_eq!(
            err.data.unwrap()["reason"],
            "admin_challenge_chain_mismatch"
        );

        let key = store.begin(request("rotate_bundler_eoa"));
        let err = store
            .consume(
                &AdminAuthorization {
                    admin_action_id: key.id,
                    nonce: key.nonce,
                },
                "rotate_bundler_eoa",
                "default",
                1,
                Some("other-key"),
            )
            .unwrap_err();
        assert_eq!(err.data.unwrap()["reason"], "admin_challenge_key_mismatch");

        let nonce = store.begin(request("rotate_bundler_eoa"));
        let err = store
            .consume(
                &AdminAuthorization {
                    admin_action_id: nonce.id,
                    nonce: "wrong".to_string(),
                },
                "rotate_bundler_eoa",
                "default",
                1,
                Some("key"),
            )
            .unwrap_err();
        assert_eq!(
            err.data.unwrap()["reason"],
            "admin_challenge_nonce_mismatch"
        );

        let expired = store.begin(request("rotate_bundler_eoa"));
        store.force_monotonic_expire(&expired.id);
        let err = store
            .consume(
                &AdminAuthorization {
                    admin_action_id: expired.id,
                    nonce: expired.nonce,
                },
                "rotate_bundler_eoa",
                "default",
                1,
                Some("key"),
            )
            .unwrap_err();
        assert_eq!(err.data.unwrap()["reason"], "admin_challenge_expired");
    }

    #[test]
    fn challenge_expiry_uses_monotonic_clock_not_wall_clock() {
        let store = AdminChallengeStore::default();
        let challenge = store.begin(request("rotate_bundler_eoa"));
        let auth = AdminAuthorization {
            admin_action_id: challenge.id.clone(),
            nonce: challenge.nonce.clone(),
        };

        store.force_monotonic_expire(&challenge.id);

        let err = store
            .consume(&auth, "rotate_bundler_eoa", "default", 1, Some("key"))
            .unwrap_err();
        assert_eq!(err.data.unwrap()["reason"], "admin_challenge_expired");
    }

    #[test]
    fn replacement_for_same_scope_invalidates_prior_challenge() {
        let store = AdminChallengeStore::default();
        let first = store.begin(request("rotate_bundler_eoa"));
        let second = store.begin(request("rotate_bundler_eoa"));

        let err = store
            .consume(
                &AdminAuthorization {
                    admin_action_id: first.id,
                    nonce: first.nonce,
                },
                "rotate_bundler_eoa",
                "default",
                1,
                Some("key"),
            )
            .unwrap_err();
        assert_eq!(err.data.unwrap()["reason"], "admin_challenge_missing");

        assert!(store
            .consume(
                &AdminAuthorization {
                    admin_action_id: second.id,
                    nonce: second.nonce,
                },
                "rotate_bundler_eoa",
                "default",
                1,
                Some("key"),
            )
            .is_ok());
    }
}
