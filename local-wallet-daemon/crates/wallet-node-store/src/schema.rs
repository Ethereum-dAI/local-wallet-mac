pub const SCHEMA_V1: &str = r#"
-- migration applies: PRAGMA user_version = 1;

CREATE TABLE daemon_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE bundler_accounts (
  chain_id   INTEGER NOT NULL,
  address    TEXT    NOT NULL,
  key_ref    TEXT    NOT NULL,    -- Keychain account name, e.g. "bundler-eoa:1"
  lifecycle  TEXT    NOT NULL DEFAULT 'active',  -- 'active' | 'retiring' | 'retired'
  created_at INTEGER NOT NULL,
  PRIMARY KEY (chain_id, address)
);

CREATE TABLE nonce_reservations (
  chain_id        INTEGER NOT NULL,
  bundler_address TEXT    NOT NULL,
  nonce           INTEGER NOT NULL,
  status          TEXT    NOT NULL,
  user_op_hash    TEXT,
  tx_hash         TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (chain_id, bundler_address, nonce)
);

CREATE TABLE user_operations (
  user_op_hash TEXT    PRIMARY KEY,
  chain_id     INTEGER NOT NULL,
  entry_point  TEXT    NOT NULL,
  sender       TEXT    NOT NULL,
  nonce        TEXT    NOT NULL,   -- 256-bit, hex-encoded
  user_op_json TEXT    NOT NULL,
  status       TEXT    NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);

CREATE TABLE submitted_transactions (
  tx_hash               TEXT    PRIMARY KEY,
  user_op_hash          TEXT    NOT NULL,
  chain_id              INTEGER NOT NULL,
  bundler_address       TEXT    NOT NULL,
  nonce                 INTEGER NOT NULL,
  raw_tx                TEXT    NOT NULL,
  max_fee_per_gas       TEXT    NOT NULL,
  max_priority_fee_per_gas TEXT NOT NULL,
  status                TEXT    NOT NULL,
  replacement_of        TEXT,
  submitted_at_block    INTEGER,    -- 64-bit; do not narrow to i32 in Rust
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL
);

CREATE TABLE user_operation_receipts (
  user_op_hash      TEXT    PRIMARY KEY,
  tx_hash           TEXT    NOT NULL,
  success           INTEGER NOT NULL,
  actual_gas_cost   TEXT,
  actual_gas_used   TEXT,
  revert_reason     TEXT,
  receipt_json      TEXT    NOT NULL,
  tentative         INTEGER NOT NULL DEFAULT 0, -- 1 when reconciled without Helios verification
  created_at        INTEGER NOT NULL
);

CREATE INDEX idx_submitted_status
  ON submitted_transactions(status, updated_at);

CREATE INDEX idx_nonce_tx_hash
  ON nonce_reservations(tx_hash)
  WHERE tx_hash IS NOT NULL;

CREATE INDEX idx_user_op_status
  ON user_operations(status, updated_at);
"#;

pub const SCHEMA_V2: &str = r#"
CREATE TABLE operation_diagnostics (
  subject_type  TEXT    NOT NULL,
  subject_id    TEXT    NOT NULL,
  last_error    TEXT    NOT NULL,
  last_error_at INTEGER NOT NULL,
  PRIMARY KEY (subject_type, subject_id)
);

CREATE INDEX idx_operation_diagnostics_type
  ON operation_diagnostics(subject_type, last_error_at);
"#;

pub const SCHEMA_V3: &str = r#"
CREATE TABLE audit_runs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  generated_at INTEGER NOT NULL,
  chain_id     INTEGER NOT NULL,
  synced       INTEGER NOT NULL,
  summary_json TEXT    NOT NULL
);

CREATE TABLE audit_findings (
  run_id                    INTEGER NOT NULL,
  source                    TEXT    NOT NULL,
  severity                  TEXT    NOT NULL,
  code                      TEXT    NOT NULL,
  table_name                TEXT,
  subject                   TEXT,
  message                   TEXT    NOT NULL,
  suggested_action          TEXT,
  recommended_repair_action TEXT,
  FOREIGN KEY(run_id) REFERENCES audit_runs(id) ON DELETE CASCADE
);

CREATE INDEX idx_audit_runs_generated_at
  ON audit_runs(generated_at);

CREATE INDEX idx_audit_findings_run_id
  ON audit_findings(run_id);
"#;

pub const SCHEMA_V4: &str = r#"
ALTER TABLE bundler_accounts ADD COLUMN owner_scope TEXT NOT NULL DEFAULT 'default';
ALTER TABLE bundler_accounts ADD COLUMN activated_at INTEGER;
ALTER TABLE bundler_accounts ADD COLUMN retired_at INTEGER;
ALTER TABLE bundler_accounts ADD COLUMN deleted_at INTEGER;
ALTER TABLE bundler_accounts ADD COLUMN last_used_at INTEGER;
ALTER TABLE bundler_accounts ADD COLUMN last_exported_at INTEGER;
ALTER TABLE bundler_accounts ADD COLUMN compromise_status TEXT;

CREATE UNIQUE INDEX idx_bundler_accounts_one_active_owner_chain
  ON bundler_accounts(owner_scope, chain_id)
  WHERE lifecycle = 'active';

CREATE UNIQUE INDEX idx_bundler_accounts_one_pending_owner_chain
  ON bundler_accounts(owner_scope, chain_id)
  WHERE lifecycle = 'pending_funding';

CREATE TABLE relayer_key_audit_events (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  event_type         TEXT    NOT NULL,
  owner_scope        TEXT    NOT NULL,
  chain_id           INTEGER NOT NULL,
  key_ref            TEXT,
  address            TEXT,
  previous_lifecycle TEXT,
  new_lifecycle      TEXT,
  admin_action_id    TEXT,
  result             TEXT    NOT NULL,
  failure_reason     TEXT,
  created_at         INTEGER NOT NULL
);

CREATE INDEX idx_relayer_key_audit_events_scope_chain
  ON relayer_key_audit_events(owner_scope, chain_id, created_at);
"#;

pub const SCHEMA_V5: &str = r#"
DROP INDEX IF EXISTS idx_bundler_accounts_one_active_owner_chain;
DROP INDEX IF EXISTS idx_bundler_accounts_one_pending_owner_chain;
DROP INDEX IF EXISTS idx_nonce_tx_hash;
DROP INDEX IF EXISTS idx_user_op_status;
DROP INDEX IF EXISTS idx_submitted_status;

ALTER TABLE bundler_accounts RENAME TO bundler_accounts_v4;
UPDATE bundler_accounts_v4 SET lifecycle = lower(lifecycle);
CREATE TABLE bundler_accounts_v4_quarantine (
  owner_scope    TEXT,
  chain_id       INTEGER,
  address        TEXT,
  column_name    TEXT NOT NULL,
  original_value TEXT,
  migrated_at    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE TABLE bundler_accounts (
  chain_id              INTEGER NOT NULL,
  address               TEXT    NOT NULL,
  key_ref               TEXT    NOT NULL,
  lifecycle             TEXT    NOT NULL DEFAULT 'active'
    CHECK (lifecycle IN ('active', 'pending_funding', 'retiring', 'retired', 'deleted')),
  created_at            INTEGER NOT NULL,
  owner_scope           TEXT    NOT NULL DEFAULT 'default',
  activated_at          INTEGER,
  retired_at            INTEGER,
  deleted_at            INTEGER,
  last_used_at          INTEGER,
  last_exported_at      INTEGER,
  compromise_status     TEXT,
  PRIMARY KEY (owner_scope, chain_id, address)
);
INSERT INTO bundler_accounts (
  chain_id, address, key_ref, lifecycle, created_at, owner_scope, activated_at, retired_at,
  deleted_at, last_used_at, last_exported_at, compromise_status
)
SELECT
  chain_id, address, key_ref,
  CASE lower(lifecycle)
    WHEN 'retiring' THEN 'deleted'
    WHEN 'retired' THEN 'deleted'
    ELSE lower(lifecycle)
  END AS lifecycle,
  created_at, owner_scope, activated_at, retired_at,
  deleted_at, last_used_at, last_exported_at, compromise_status
FROM bundler_accounts_v4
WHERE CASE lower(lifecycle)
    WHEN 'retiring' THEN 'deleted'
    WHEN 'retired' THEN 'deleted'
    ELSE lower(lifecycle)
  END IN ('active', 'pending_funding', 'deleted');
INSERT INTO bundler_accounts_v4_quarantine (
  owner_scope, chain_id, address, column_name, original_value
)
SELECT owner_scope, chain_id, address, 'lifecycle', lifecycle
FROM bundler_accounts_v4
WHERE CASE lower(lifecycle)
    WHEN 'retiring' THEN 'deleted'
    WHEN 'retired' THEN 'deleted'
    ELSE lower(lifecycle)
  END NOT IN ('active', 'pending_funding', 'deleted');
DROP TABLE bundler_accounts_v4;

ALTER TABLE nonce_reservations RENAME TO nonce_reservations_v4;
UPDATE nonce_reservations_v4 SET status = lower(status);
CREATE TABLE nonce_reservations_v4_quarantine (
  chain_id        INTEGER,
  bundler_address TEXT,
  nonce           INTEGER,
  column_name     TEXT NOT NULL,
  original_value  TEXT,
  migrated_at     INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE TABLE nonce_reservations (
  chain_id        INTEGER NOT NULL,
  bundler_address TEXT    NOT NULL,
  nonce           INTEGER NOT NULL,
  status          TEXT    NOT NULL
    CHECK (status IN ('reserved', 'submitted', 'included', 'failed', 'replaced', 'abandoned')),
  user_op_hash    TEXT,
  tx_hash         TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (chain_id, bundler_address, nonce)
);
INSERT INTO nonce_reservations_v4_quarantine (
  chain_id, bundler_address, nonce, column_name, original_value
)
SELECT chain_id, bundler_address, nonce, 'status', status
FROM nonce_reservations_v4
WHERE status NOT IN ('reserved', 'submitted', 'included', 'failed', 'replaced', 'abandoned');
-- Coercion considered: no legacy nonce_reservations.status values found in history.
INSERT INTO nonce_reservations (
  chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at
)
SELECT chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at
FROM nonce_reservations_v4
WHERE status IN ('reserved', 'submitted', 'included', 'failed', 'replaced', 'abandoned');
DROP TABLE nonce_reservations_v4;

ALTER TABLE user_operations RENAME TO user_operations_v4;
UPDATE user_operations_v4 SET status = lower(status);
CREATE TABLE user_operations_v4_quarantine (
  user_op_hash   TEXT,
  column_name    TEXT NOT NULL,
  original_value TEXT,
  migrated_at    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE TABLE user_operations (
  user_op_hash TEXT    PRIMARY KEY,
  chain_id     INTEGER NOT NULL,
  entry_point  TEXT    NOT NULL,
  sender       TEXT    NOT NULL,
  nonce        TEXT    NOT NULL,
  user_op_json TEXT    NOT NULL,
  status       TEXT    NOT NULL
    CHECK (status IN ('received', 'simulated', 'submitted', 'included', 'reverted', 'failed', 'pending')),
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);
INSERT INTO user_operations_v4_quarantine (
  user_op_hash, column_name, original_value
)
SELECT user_op_hash, 'status', status
FROM user_operations_v4
WHERE status NOT IN ('received', 'simulated', 'submitted', 'included', 'reverted', 'failed', 'pending');
-- Coercion considered: no legacy user_operations.status values found in history.
INSERT INTO user_operations (
  user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at
)
SELECT user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at
FROM user_operations_v4
WHERE status IN ('received', 'simulated', 'submitted', 'included', 'reverted', 'failed', 'pending');
DROP TABLE user_operations_v4;

ALTER TABLE submitted_transactions RENAME TO submitted_transactions_v4;
UPDATE submitted_transactions_v4 SET status = lower(status);
CREATE TABLE submitted_transactions_v4_quarantine (
  tx_hash        TEXT,
  column_name    TEXT NOT NULL,
  original_value TEXT,
  migrated_at    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE TABLE submitted_transactions (
  tx_hash                  TEXT    PRIMARY KEY,
  user_op_hash             TEXT    NOT NULL,
  chain_id                 INTEGER NOT NULL,
  bundler_address          TEXT    NOT NULL,
  nonce                    INTEGER NOT NULL,
  raw_tx                   TEXT    NOT NULL,
  max_fee_per_gas          TEXT    NOT NULL,
  max_priority_fee_per_gas TEXT    NOT NULL,
  status                   TEXT    NOT NULL
    CHECK (status IN ('submitting', 'submitted', 'included', 'dropped', 'replaced', 'abandoned', 'failed')),
  replacement_of           TEXT,
  submitted_at_block       INTEGER,
  created_at               INTEGER NOT NULL,
  updated_at               INTEGER NOT NULL
);
INSERT INTO submitted_transactions_v4_quarantine (
  tx_hash, column_name, original_value
)
SELECT tx_hash, 'status', status
FROM submitted_transactions_v4
WHERE status NOT IN ('submitting', 'submitted', 'included', 'dropped', 'replaced', 'abandoned', 'failed');
-- Coercion considered: no legacy submitted_transactions.status values found in history.
INSERT INTO submitted_transactions_v4_quarantine (
  tx_hash, column_name, original_value
)
SELECT tx_hash, 'user_op_hash', user_op_hash
FROM submitted_transactions_v4
WHERE status IN ('submitting', 'submitted', 'included', 'dropped', 'replaced', 'abandoned', 'failed')
  AND user_op_hash NOT IN (SELECT user_op_hash FROM user_operations);
INSERT INTO submitted_transactions (
  tx_hash, user_op_hash, chain_id, bundler_address, nonce, raw_tx, max_fee_per_gas,
  max_priority_fee_per_gas, status, replacement_of, submitted_at_block, created_at, updated_at
)
SELECT
  tx_hash, user_op_hash, chain_id, bundler_address, nonce, raw_tx, max_fee_per_gas,
  max_priority_fee_per_gas, status, replacement_of, submitted_at_block, created_at, updated_at
FROM submitted_transactions_v4
WHERE status IN ('submitting', 'submitted', 'included', 'dropped', 'replaced', 'abandoned', 'failed')
  AND user_op_hash IN (SELECT user_op_hash FROM user_operations);
DROP TABLE submitted_transactions_v4;

ALTER TABLE user_operation_receipts RENAME TO user_operation_receipts_v4;
UPDATE user_operation_receipts_v4
SET success = CASE lower(CAST(success AS TEXT))
  WHEN 'true' THEN 1
  WHEN 'false' THEN 0
  ELSE success
END;
UPDATE user_operation_receipts_v4
SET tentative = CASE lower(CAST(tentative AS TEXT))
  WHEN 'true' THEN 1
  WHEN 'false' THEN 0
  ELSE tentative
END;
CREATE TABLE user_operation_receipts_v4_quarantine (
  user_op_hash   TEXT,
  column_name    TEXT NOT NULL,
  original_value TEXT,
  migrated_at    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE TABLE user_operation_receipts (
  user_op_hash      TEXT    PRIMARY KEY,
  tx_hash           TEXT    NOT NULL,
  success           INTEGER NOT NULL CHECK (success IN (0, 1)),
  actual_gas_cost   TEXT,
  actual_gas_used   TEXT,
  revert_reason     TEXT,
  receipt_json      TEXT    NOT NULL,
  tentative         INTEGER NOT NULL DEFAULT 0 CHECK (tentative IN (0, 1)),
  created_at        INTEGER NOT NULL
);
INSERT INTO user_operation_receipts_v4_quarantine (
  user_op_hash, column_name, original_value
)
SELECT user_op_hash, 'success', CAST(success AS TEXT)
FROM user_operation_receipts_v4
WHERE success NOT IN (0, 1);
INSERT INTO user_operation_receipts_v4_quarantine (
  user_op_hash, column_name, original_value
)
SELECT user_op_hash, 'tentative', CAST(tentative AS TEXT)
FROM user_operation_receipts_v4
WHERE tentative NOT IN (0, 1);
INSERT INTO user_operation_receipts_v4_quarantine (
  user_op_hash, column_name, original_value
)
SELECT user_op_hash, 'user_op_hash', user_op_hash
FROM user_operation_receipts_v4
WHERE success IN (0, 1)
  AND tentative IN (0, 1)
  AND user_op_hash NOT IN (SELECT user_op_hash FROM user_operations);
INSERT INTO user_operation_receipts (
  user_op_hash, tx_hash, success, actual_gas_cost, actual_gas_used, revert_reason,
  receipt_json, tentative, created_at
)
SELECT
  user_op_hash, tx_hash, success, actual_gas_cost, actual_gas_used, revert_reason,
  receipt_json, tentative, created_at
FROM user_operation_receipts_v4
WHERE success IN (0, 1)
  AND tentative IN (0, 1)
  AND user_op_hash IN (SELECT user_op_hash FROM user_operations);
DROP TABLE user_operation_receipts_v4;

CREATE UNIQUE INDEX idx_bundler_accounts_one_active_owner_chain
  ON bundler_accounts(owner_scope, chain_id)
  WHERE lifecycle = 'active';

CREATE UNIQUE INDEX idx_bundler_accounts_one_pending_owner_chain
  ON bundler_accounts(owner_scope, chain_id)
  WHERE lifecycle = 'pending_funding';

CREATE INDEX idx_submitted_status
  ON submitted_transactions(status, updated_at);

CREATE INDEX idx_nonce_tx_hash
  ON nonce_reservations(tx_hash)
  WHERE tx_hash IS NOT NULL;

CREATE INDEX idx_user_op_status
  ON user_operations(status, updated_at);
"#;

pub const SCHEMA_V6: &str = r#"
ALTER TABLE user_operation_receipts
  ADD COLUMN invalidated INTEGER NOT NULL DEFAULT 0 CHECK (invalidated IN (0, 1));
"#;

pub const SCHEMA_V7: &str = r#"
ALTER TABLE submitted_transactions
  ADD COLUMN recovery_attempts INTEGER NOT NULL DEFAULT 0;
"#;
