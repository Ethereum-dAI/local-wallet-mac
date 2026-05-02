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
