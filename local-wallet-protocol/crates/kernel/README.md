# wallet-kernel

> **Status:** Open source under MIT/Apache-2.0. Stable public API; pre-1.0 (0.x), so under Cargo's semver breaking changes ship as a minor (0.x) version bump.

Kernel-specific helpers for WebAuthn-root smart accounts.

This crate is intentionally narrower than a wallet SDK and more specific than
`wallet-signature`. It handles the deterministic Kernel account pieces that are
useful to wallets, scripts, and infrastructure code:

- `ValidationId` construction for a WebAuthn root validator
- ABI encoding for `WebAuthnValidatorData`
- `Kernel.initialize(...)` calldata generation
- CREATE2 salt derivation for the Kernel factory flow
- Solady ERC-1967 clone init-code hashing
- counterfactual Kernel account address prediction
- Kernel v3 nonce decoding via `KernelNonce::decode` (validation mode, validation type, validation id, parallel key, sequence)
- Kernel v3.3 modular-permission session-key encoding: policy composition, permission ID derivation, enable-data construction, EIP-712 enable digest, and permission lifecycle calldata (install / revoke)

It does **not** handle:

- Secure Enclave / Keychain access
- WebAuthn signing-message construction
- P-256 signature parsing or low-s normalization
- bundler or RPC transport
- deployed Kernel module enumeration
- live allowlist manifest promotion

Those runtime checks live in the daemon stack, primarily `wallet-bundler` and `wallet-node`.

The pinned Kernel factory, implementation, and WebAuthn validator addresses used by the daemon's app-shaped path live in [`wallet-bundler/src/allowlist.rs`](https://github.com/Ethereum-dAI/local-wallet-daemon/blob/main/crates/wallet-bundler/src/allowlist.rs), not here. This crate is generic over those addresses.

## Install

Add the crate as a git dependency in your `Cargo.toml`:

```toml
[dependencies]
wallet-kernel = { git = "https://github.com/Ethereum-dAI/local-wallet-protocol.git", rev = "770ac6798447da03f388e01bb0ccce7a79e843e9" }
```

> The modular-permission / session-key APIs documented below ship after the `v0.1.0` tag, so pin a `rev`/tag that includes the permission module (the `770ac67` rev above does).

Pin a specific commit instead of a tag with `rev = "<sha>"` when you need an exact lock. Once the crate is published to crates.io a version-based dependency will also be available.

## Usage

The examples below use the test-vector addresses from `local-wallet-protocol`. Replace them with the factory/implementation/validator your stack pins.

### Build a `ValidationId` for a WebAuthn root validator

```rust
use alloy_primitives::address;
use wallet_kernel::build_validation_id;

let validation_id = build_validation_id(
    address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"),
);
// `validation_id: FixedBytes<21>` packs [VALIDATOR_TYPE, validator_address].
```

### ABI-encode `WebAuthnValidatorData`

```rust
use alloy_primitives::{B256, U256};
use wallet_kernel::encode_webauthn_validator_data;

let encoded = encode_webauthn_validator_data(
    U256::from(1u64),  // pub_key_x
    U256::from(2u64),  // pub_key_y
    B256::ZERO,        // authenticator_id_hash
);
// `abi.encode(uint256 pubKeyX, uint256 pubKeyY, bytes32 authenticatorIdHash)`.
```

### Build `Kernel.initialize(...)` calldata

```rust
use alloy_primitives::{address, B256, U256};
use wallet_kernel::encode_initialize_call;

let init_data = encode_initialize_call(
    address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"), // WebAuthn validator
    U256::from(1u64),                                    // pub_key_x
    U256::from(2u64),                                    // pub_key_y
    B256::ZERO,                                          // authenticator_id_hash
);
// `init_data` is the bytes payload the Kernel factory consumes via createAccount(initData, salt).
```

### Derive the CREATE2 salt the factory actually uses

```rust
use alloy_primitives::B256;
use wallet_kernel::compute_actual_salt;

let actual_salt = compute_actual_salt(&init_data, B256::ZERO);
// `actual_salt = keccak256(initData ‖ userSalt)`.
```

### Solady ERC-1967 clone init-code hash

```rust
use alloy_primitives::address;
use wallet_kernel::erc1967_init_code_hash;

let kernel_impl = address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28");
let init_code_hash = erc1967_init_code_hash(kernel_impl);
```

### Predict a counterfactual Kernel account end-to-end

```rust
use alloy_primitives::{address, B256, U256};
use wallet_kernel::predict_kernel_account_address;

let predicted = predict_kernel_account_address(
    address!("2577507b78c2008Ff367261CB6285d44ba5eF2E9"), // factory
    address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28"), // Kernel implementation
    address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"), // WebAuthn validator
    U256::from(1u64),                                    // pub_key_x
    U256::from(2u64),                                    // pub_key_y
    B256::ZERO,                                          // authenticator_id_hash
    B256::ZERO,                                          // user-chosen salt
);

assert_eq!(predicted, address!("ea18d505d23f0b73a91409cd468aecf3beab03ba"));
```

### Decode a Kernel v3 nonce

```rust
use alloy_primitives::U256;
use wallet_kernel::KernelNonce;

let nonce = U256::from(0u64);
let decoded = KernelNonce::decode(nonce);
// decoded.validation_mode, .validation_type, .validation_id_without_type,
// .parallel_key, .sequence — the upper nonce bits carry Kernel validation meaning,
// not just parallel lanes.
```

### Compose a session-key permission and derive its ID

```rust
use alloy_primitives::{address, Address, U256};
use wallet_kernel::{
    call_policy, ecdsa_signer_entry, gas_policy, permission_id,
    rate_limit_policy, timestamp_policy, AllowedCall,
};

let usdc = address!("1c7D4B196Cb0C7B01d743Fbc6116a902379C7238");
let session_key = address!("90F8bf6A479f320ead074411a4B0e7944Ea8c9C1");

let policies = vec![
    gas_policy(5_000_000_000_000_000, false, Address::ZERO),
    rate_limit_policy(86400, 20, 0),
    timestamp_policy(0, 1_900_000_000),
    call_policy(&[
        AllowedCall {
            target: usdc,
            selector: [0xa9, 0x05, 0x9c, 0xbb], // transfer
            value_limit: U256::ZERO,
            rules: vec![],
        },
        AllowedCall {
            target: usdc,
            selector: [0x09, 0x5e, 0xa7, 0xb3], // approve
            value_limit: U256::ZERO,
            rules: vec![],
        },
    ]),
];

let (signer_contract, signer_data) = ecdsa_signer_entry(session_key);
let pid = permission_id(&policies, signer_contract, &signer_data);
// `pid: [u8; 4]` — the first 4 bytes of the keccak hash over the permission configuration.
```

### Build enable-data for on-chain permission installation

```rust
use wallet_kernel::encode_enable_data;

let enable_data = encode_enable_data(&policies, signer_contract, &signer_data);
// `enable_data` is the ABI-encoded blob the Kernel modular-permission validator
// consumes to install the session key on-chain.
```

### Compute the EIP-712 enable digest for owner approval

```rust
use alloy_primitives::{address, Address};
use wallet_kernel::{
    enable_digest, encode_selector_data_default_action, permission_validation_id,
};

let account = address!("000000000000000000000000000000000000dEaD");
let chain_id = 11155111u64;
let validation_id = permission_validation_id(pid);
let selector_data = encode_selector_data_default_action([0xe9, 0xae, 0x5c, 0x53]);

let digest = enable_digest(
    account,
    chain_id,
    validation_id,
    1,                  // validation nonce
    Address::ZERO,      // hook
    &enable_data,       // validator data
    &[],                // hook data
    &selector_data,
);
// `digest: B256` — sign this with the account owner's key to authorize the permission.
```

### Install a permission (root-validated)

```rust
use wallet_kernel::{
    grant_access_calldata, install_validations_calldata, KERNEL_EXECUTE_SELECTOR,
};

// Install the permission as a root(owner)-validated op so the (expensive)
// install runs in the execution phase and is NOT charged against the
// permission's own GasPolicy. `nonce` must equal the account's `currentNonce()`
// at install time, else Kernel reverts `InvalidNonce`. `enable_data` is the
// same blob produced above for enable-mode.
let current_nonce = 0u32; // = account.currentNonce()
let install_calldata = install_validations_calldata(pid, current_nonce, &enable_data, &[]);

// Grant the installed permission access to the session `execute` selector.
let grant_calldata = grant_access_calldata(pid, KERNEL_EXECUTE_SELECTOR);
```

### Revoke a permission

```rust
use wallet_kernel::{invalidate_nonce_calldata, uninstall_permission_calldata};

// Invalidate the permission nonce (prevents further use).
let calldata = invalidate_nonce_calldata(7);

// Or fully uninstall the permission validation.
let calldata = uninstall_permission_calldata(pid, &[]);
```

## Public surface

| Helper | Purpose |
|---|---|
| `build_validation_id` | Pack `[VALIDATOR_TYPE, validator_address]` into a `FixedBytes<21>` ValidationId |
| `encode_webauthn_validator_data` | `abi.encode(uint256 pubKeyX, uint256 pubKeyY, bytes32 authenticatorIdHash)` |
| `encode_initialize_call` | Full `Kernel.initialize(...)` calldata for a WebAuthn root validator |
| `compute_actual_salt` | `keccak256(initData ‖ userSalt)` — the salt the Kernel factory actually hashes into CREATE2 |
| `erc1967_init_code_hash` | Solady minimal-proxy init-code hash for a given Kernel implementation |
| `predict_create2_address` | Generic CREATE2 from `(factory, actualSalt, initCodeHash)` |
| `predict_kernel_account_address` | Counterfactual Kernel account address, end-to-end |
| `KernelNonce::decode` | Split a Kernel v3 nonce into mode / type / validation-id / parallel-key / sequence |
| `permission_id` | Derive the 4-byte permission ID from policies + signer |
| `encode_enable_data` | ABI-encode the full permission blob for on-chain installation |
| `enable_digest` | EIP-712 typed-data hash the account owner signs to approve a permission |
| `enable_type_hash` | The `Enable` struct EIP-712 type hash constant |
| `encode_selector_data_default_action` | Selector-data blob for the default execute action |
| `permission_validation_id` | Pack a permission ID into a 21-byte validation ID |
| `encode_permission_nonce_key` | EntryPoint nonce key with permission mode and ID in the upper bits |
| `gas_policy` | Policy entry: gas allowance with optional paymaster enforcement |
| `rate_limit_policy` | Policy entry: interval / count / start-at rate limit |
| `timestamp_policy` | Policy entry: valid-after / valid-until time window |
| `sudo_policy` | Policy entry: unrestricted (empty data) |
| `call_policy` | Policy entry: per-target, per-selector call permissions with optional param rules |
| `ecdsa_signer_entry` | Signer entry for the ECDSA signer module |
| `encode_gas_policy_data` | Raw ABI encoding for the gas policy |
| `encode_rate_limit_policy_data` | Raw packed encoding for the rate-limit policy |
| `encode_timestamp_policy_data` | Raw ABI encoding for the timestamp policy |
| `encode_sudo_policy_data` | Raw encoding for the sudo policy (empty) |
| `encode_call_policy_data` | Raw ABI encoding for the call policy |
| `encode_ecdsa_signer_data` | Raw encoding for the ECDSA signer |
| `invalidate_nonce_calldata` | `invalidateNonce(uint32)` calldata for permission nonce revocation |
| `uninstall_permission_calldata` | `uninstallValidation(bytes21, bytes, bytes)` calldata for full permission removal |
| `install_validations_calldata` | `installValidations(...)` calldata to install a permission as a root-validated op, so the install is not charged against the permission's own GasPolicy |
| `grant_access_calldata` | `grantAccess(bytes21, bytes4, bool)` calldata to grant an installed permission access to a selector |
| `policy_info` | Pack a policy flag and address into a 22-byte info blob |

| Type | Purpose |
|---|---|
| `PolicyEntry` | `(Vec<u8>, Vec<u8>)` — policy info + data pair |
| `AllowedCall` | Target, selector, value limit, and param rules for a call policy entry |
| `AllowRule` | Condition + offset + reference params for a call-policy parameter rule |
| `Condition` | Enum of param-rule conditions: Equal, GreaterThan, LessThan, GreaterEqual, LessEqual, NotEqual, OneOf, SliceEqual |

| Constant | Value | Meaning |
|---|---|---|
| `VALIDATOR_TYPE` | `0x01` | Prefix byte in a Kernel `ValidationId` |
| `VALIDATION_MODE_DEFAULT` / `_ENABLE` / `_INSTALL` | `0x00` / `0x01` / `0x02` | Nonce validation-mode field |
| `VALIDATION_TYPE_ROOT` / `_VALIDATOR` / `_PERMISSION` | `0x00` / `0x01` / `0x02` | Nonce validation-type field |
| `KERNEL_EXECUTE_SELECTOR` | `0xe9ae5c53` | `execute(bytes32,bytes)` selector session user ops call; a permission must be granted access to it |
| `KERNEL_NO_HOOK` | `address(1)` | Sentinel for "no hook" in a Kernel `ValidationConfig` |

For full type signatures and inline docs, run `cargo doc --open -p wallet-kernel`.

## Testing

```bash
cargo test -p wallet-kernel
```

The permission module is tested against golden vectors generated by the TypeScript SDK (`tooling/golden-vectors/`), ensuring byte-level compatibility for permission ID derivation, enable-data encoding, and EIP-712 digest computation.

The app-pinned deployed Kernel path is also covered by the mainnet-fork fixture, which lives in the daemon repo:

```bash
ETH_RPC_URL=https://your-mainnet-rpc.example \
WALLET_FORK_BLOCK_NUMBER=25001071 \
# run from local-wallet-daemon: https://github.com/Ethereum-dAI/local-wallet-daemon
scripts/run-kernel-mainnet-fork-check.sh
```