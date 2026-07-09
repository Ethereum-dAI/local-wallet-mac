# wallet-signature

> **Status:** Open source under MIT/Apache-2.0. Stable public API; breaking changes ship as a major version per semver.

Cryptographic foundation for WebAuthn/P-256 signing flows used with ERC-4337 smart accounts.

This crate takes known inputs and produces known outputs. It is purely synchronous, has no FFI, and no networking. The Secure Enclave ROOT P-256 key never enters Rust; however, session-key (secp256k1) secrets ARE passed into this crate for the permission/session-key signing path (see the `permission` module).

Kernel-specific account helpers such as `initialize(...)` calldata encoding and counterfactual address prediction now live in the companion crate [`wallet-kernel`](../kernel/README.md).

## Install

Add the crate as a git dependency in your `Cargo.toml`:

```toml
[dependencies]
wallet-signature = { git = "https://github.com/Ethereum-dAI/local-wallet-protocol.git", rev = "770ac6798447da03f388e01bb0ccce7a79e843e9" }
```

The `permission` module and the session-key helpers documented below were added after the `v0.1.0` tag, so pin a `rev`/tag that includes that API (the `rev` above does). Pin a specific commit instead of a tag with `rev = "<sha>"` when you need an exact lock. Once the crate is published to crates.io a version-based dependency will also be available.

## What it does

Given a `PackedUserOperation` and a P-256 signature from the Secure Enclave, this crate produces the exact byte sequence that the [Kernel WebAuthn validator](https://github.com/zerodevapp/kernel-7579-plugins/tree/master/validators/webauthn) expects on-chain.

The pipeline:

```
PackedUserOperation
        |
        v
  compute_userop_hash()          -- keccak256, EntryPoint v0.7 scheme
        |
        v
  compute_signing_message()      -- final 32-byte sha256 digest
        |
        v
  [Secure Enclave signs this]    -- Swift/CryptoKit, outside this crate
        |
        v
  normalise_low_s()              -- mandatory, validator rejects high-s
        |
        v
  build_signature()              -- assembles WebAuthnSignature struct
        |
        v
  abi_encode_webauthn_signature() -- ABI bytes for the UserOp.signature field
```

## Usage

```rust
use wallet_signature::*;
use alloy_primitives::{address, Bytes, FixedBytes, U256};

// 1. Build the UserOperation
let userop = PackedUserOperation {
    sender: address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2"),
    nonce: U256::from(1u64),
    init_code: Bytes::new(),
    call_data: Bytes::from(/* your calldata */),
    account_gas_limits: FixedBytes::from(/* packed verificationGasLimit | callGasLimit */),
    pre_verification_gas: U256::from(21000u64),
    gas_fees: FixedBytes::from(/* packed maxPriorityFeePerGas | maxFeePerGas */),
    paymaster_and_data: Bytes::new(),
};

// 2. Compute the UserOp hash (what the EntryPoint computes on-chain)
let userop_hash: [u8; 32] = compute_userop_hash(&userop, ENTRY_POINT_V07, 1);

// 3. Compute the final signing message used for verification/tests
let (signing_message, _client_data_json) = compute_signing_message(&userop_hash);

// 4. In the app path, Swift signs the 69-byte preimage
//    `authenticatorData || sha256(clientDataJSON)` via FFI:
//    let preimage = try WalletSignature.computeSigningPreimage(userOpHash: ...)
//    let signature = try key.signature(for: preimage)
//    CryptoKit hashes the preimage internally before signing.
//    Extract r, s from the CryptoKit signature (rawRepresentation: 64 bytes, r || s)
let r: [u8; 32] = /* first 32 bytes from Enclave */;
let s: [u8; 32] = /* last 32 bytes from Enclave */;

// 5. Normalise to low-s (mandatory -- validator rejects high-s)
let (r, s) = normalise_low_s(r, s);

// 6. Build the WebAuthn signature struct
let sig = build_signature(&userop_hash, r, s, true /* use RIP-7212 precompile */);

// 7. ABI-encode for the UserOp.signature field
let encoded: Vec<u8> = abi_encode_webauthn_signature(&sig);
// `encoded` goes into the UserOperation's `signature` field
```

## Modules

### `userop_hash` -- UserOperation hashing

Computes the UserOp hash exactly as EntryPoint v0.7 does. This is **not** EIP-712 -- it is a simpler nested `keccak256(abi.encode(...))` scheme with no `\x19\x01` prefix and no domain separator. The `signature` field is excluded from the hash.

Verified against real mainnet transaction [`0x300f8ba6...`](https://etherscan.io/tx/0x300f8ba6cf441103424653e8508dc09999fd0f21a782e608de94e6f975553895).

### `webauthn` -- WebAuthn ceremony construction

Constructs the fields that the [Kernel WebAuthn validator](https://github.com/zerodevapp/kernel-7579-plugins/tree/master/validators/webauthn) expects:

- **`authenticatorData`** (37 bytes): `sha256("wallet")` as rpIdHash, flags `0x05` (UP+UV), sign count 0.
- **`clientDataJSON`** (full string): `{"type":"webauthn.get","challenge":"<base64url(userOpHash)>","origin":"https://wallet.local","crossOrigin":false}`. The `"challenge":` key starts at byte 23, matching the validator's hardcoded `CHALLENGE_LOCATION`.
- **`signing_message`**: `sha256(authenticatorData || sha256(clientDataJSON))` -- the final 32-byte digest validated on-chain.
- **App signing path**: Swift passes the 69-byte preimage `authenticatorData || sha256(clientDataJSON)` to `key.signature(for:)`; CryptoKit hashes it internally before producing the P-256 signature.
- **Configurable context**: advanced users can override rpId, origin, signCount, and UP/UV flags via `WebAuthnContext` while keeping the default Kernel/WebAuthn layout.

### `p256` -- P-256 signature parsing

- **`der_to_raw`**: Parses DER-encoded ECDSA signatures (from CryptoKit's `derRepresentation`) into raw 32-byte (r, s) scalars.
- **`normalise_low_s`**: Ensures `s <= n/2`. This is **mandatory** -- the Kernel validator's `P256.sol` rejects high-s signatures.
- **Typed errors**: invalid DER input now returns `SignatureError::InvalidDerEncoding`.

### `permission` -- Kernel v3.3 permission/session-key signing

Handles secp256k1 (k256) session-key signatures and the Kernel v3.3 permission signature wrappers:

- **`sign_session_userop_hash`**: Given a UserOp hash and a secp256k1 secret key, produces a 65-byte `eth_sign`-style signature (`r || s || v`). Applies the Ethereum `\x19Ethereum Signed Message:\n32` prefix and returns a recoverable signature suitable for on-chain `ecrecover`. The secret is borrowed as `&[u8; 32]` and is **not** zeroized by this crate — the caller owns the session-key secret and is responsible for zeroizing it.
- **`wrap_installed_signature`**: Prefixes an inner signature with `0xff` to produce the wrapper expected by the Kernel permission validator when the permission is already installed.
- **`wrap_enable_signature`**: Assembles the full enable-mode signature: 20 bytes of hook address followed by ABI-encoded `(validatorData, hookData, selectorData, enableSig, userOpSig)`.
- **`dummy_permission_signature_installed`** / **`dummy_permission_signature_enable`**: Build dummy signatures for gas estimation in the installed and enable paths respectively.

### `encoding` -- ABI encoding

Produces the exact byte sequence the validator decodes via:

```solidity
abi.decode(signature, (bytes, string, uint256, uint256, uint256, bool))
//                     authData, clientDataJSON, responseTypeLocation, r, s, usePrecompiled
```

The `usePrecompiled` flag controls whether on-chain verification uses the RIP-7212 precompile (`0x100`, ~3.4k gas — now standardized on mainnet as EIP-7951, ~6.9k gas post-Fusaka; `RIP-7212` remains the name used in the source code) or the Daimo P256 fallback verifier (`0xc2b78...De4`, ~330k gas).

`decode_use_precompiled(encoded)` recovers the `usePrecompiled` flag from an encoded signature, returning `None` if the bytes do not decode.

`abi_encode_dummy_signature(use_precompiled)` builds the Kernel/WebAuthn dummy signature used for gas estimation. For the deployed Kernel validator path, the dummy uses `responseTypeLocation = uint256.max`, matching the validator's sentinel path. The mainnet fork fixture in `wallet-node` validates this against deployed code through EntryPointSimulations.

## Constants

| Constant | Value | Purpose |
|---|---|---|
| `ENTRY_POINT_V07` | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | EntryPoint v0.7 address |
| `DAIMO_P256_VERIFIER` | `0xc2b78104907F722DABAc4C69f826a522B2754De4` | Fallback P-256 verifier |
| `P256_PRECOMPILE` | `0x0000000000000000000000000000000000000100` | RIP-7212 precompile |
| `RP_ID` | `"wallet"` | Default WebAuthn relying-party id |
| `ORIGIN` | `"https://wallet.local"` | Default WebAuthn origin |
| `RP_ID_HASH` | `sha256("wallet")` | rpIdHash embedded in `authenticatorData` |
| `CHALLENGE_LOCATION` | `23` | Byte offset of `"challenge":` in `clientDataJSON` (validator-mandated) |
| `RESPONSE_TYPE_LOCATION` | `1` | Byte offset of `"type":` in `clientDataJSON` (validator-mandated) |

## Default WebAuthn Context

`WebAuthnContext::default()` produces:

| Field | Value |
|---|---|
| `rp_id` | `"wallet"` |
| `origin` | `"https://wallet.local"` |
| `sign_count` | `0` |
| `user_presence` (UP) | `true` |
| `user_verification` (UV) | `true` |

The flag byte in `authenticatorData` is `0x05` (UP + UV). `sign_count = 0` because there is no real authenticator backing the Secure Enclave.

## Public Helpers

The crate re-exports the following helpers at the root:

- `compute_userop_hash` — EntryPoint v0.7 UserOp hash
- `compute_signing_message` — final 32-byte digest the validator verifies
- `build_signature` — assembles `WebAuthnSignature`
- `der_to_raw` — DER → raw `(r, s)` parser for CryptoKit's `derRepresentation`
- `normalise_low_s` — mandatory low-s normalization
- `abi_encode_webauthn_signature` — ABI-encodes the 6-field signature struct
- `abi_encode_dummy_signature` — Kernel/WebAuthn dummy signature for gas estimation
- `decode_use_precompiled` — recovers the `usePrecompiled` flag from an encoded signature
- `sign_session_userop_hash` — secp256k1 session-key `eth_sign` signature
- `wrap_installed_signature` — `0xff`-prefixed wrapper for installed permission path
- `wrap_enable_signature` — full enable-mode permission signature assembly
- `dummy_permission_signature_installed` — dummy signature for installed permission gas estimation
- `dummy_permission_signature_enable` — dummy signature for enable permission gas estimation

## Building and testing

```bash
cargo test -p wallet-signature           # run all tests
cargo clippy -p wallet-signature         # lint
cargo build -p wallet-signature --release # release build
cargo doc --open -p wallet-signature     # browse the full API reference locally
```

## What this crate does NOT do

- Networking or RPC calls
- Async operations
- FFI or C-compatible exports
- Keychain or Secure Enclave access (that's Swift's job)
- Kernel account initialization or address prediction
- Bundler communication

## Related Crates

- `wallet-kernel` for Kernel initialization and counterfactual address prediction.
- `wallet-bundler` for daemon-side EntryPoint, simulation, funding, and policy logic.
- `wallet-ffi` and `swift-bridge` for Apple consumers (both in local-wallet-mac: https://github.com/Ethereum-dAI/local-wallet-mac).