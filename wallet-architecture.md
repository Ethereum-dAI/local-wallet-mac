

**Privacy-First LLM Crypto Wallet**

Architecture & Security Design \- Ethereum

Version 5.4 \- Draft \- April 16, 2026

# **Table of Contents**

**Introduction**

**1\. Threat Model**

**2\. Self-Enclosed Architecture**

2.1 External dependency map

2.2 Helios light client

2.3 Local bundler

2.4 LLM privacy tiers

2.5 Full local architecture diagram

**3\. Account Model \- Kernel Smart Accounts (ERC-4337)**

3.1 Why Kernel smart accounts

3.2 Session signing architecture

3.3 On-chain spending policy

**4\. Key Architecture**

4.1 Three keys, three roles

4.2 User root key \- secure enclave P-256

4.3 Session key and session permissions \- macOS Keychain

4.4 Bundler operator key \- macOS Keychain

**5\. Process Architecture**

5.1 Three-tier isolation model

5.2 XPC message contract

**6\. Rust Core Library**

6.1 Philosophy

6.2 Core API surface

6.3 Cross-platform strategy

**7\. Backup and Recovery**

7.1 Recovery scenarios

7.2 User guidance at setup

7.3 Future consideration: social recovery

**8\. Multi-Account Architecture**

8.1 Key and address structure

8.2 Session key across accounts

8.3 Account creation

8.4 Restore and account discovery

**9\. Session Policy, Spending Limits, and Transaction Privacy**

9.1 Session policy and passkey fallback

9.2 Pre-inclusion privacy: Flashbots Protect

**10\. Session Duration Policy**

10.1 Timer configuration

10.2 What resets the inactivity timer

10.3 Session end behavior

**11\. UI and Platform Architecture**

11.1 Phase 1: native macOS

11.2 Future: Linux native

11.3 Tauri: later decision

**12\. Supply Chain Security**

12.1 Critical dependency surface

12.2 Mitigations

12.3 Runtime artifact provenance

**13\. Honest Security Limitations**

**14\. Tech Stack**

**15\. Out of Scope \- Phase 1**

**16\. Resolved Design Decisions**

# **Introduction**

This document describes the architecture and security design of a privacy-first, locally-run Ethereum wallet powered by a local LLM agent. The wallet is built around a single design premise: a user's cryptographic root of trust should be unextractable by software, not merely well-protected by it. Everything else follows from that.

> **Implementation status (v0.1 alpha).** This document is the cross-system design vision and runs ahead of the shipped code in places. As of v0.1 alpha the wallet uses **in-process FFI signing** (the Secure Enclave passkey signs inside the app; Rust never sees private keys), **Swift-side policy enforcement**, and a **separately spawned `wallet-node` daemon** that submits `handleOps` **directly to a bundler EOA** on Ethereum mainnet/Sepolia. Components described here that are **not yet implemented** include the XPC-isolated signing service, private submission via **Flashbots Protect / Tor (arti)**, and a bundler **compiled into the app binary**. See this repo's `README.md` "Architecture" section for the as-built design.

The wallet uses a P-256 key generated inside the device Secure Enclave as the sole ownership authority over the user's smart accounts. This key never materialises in application memory under any circumstances \- it signs inside hardware silicon and cannot be exported by any API. There is no seed phrase, no mnemonic backup, and no exportable root secret. Recovery from device loss is handled entirely on-chain via a pre-installed recovery module.

On top of this hardware root of trust, the wallet runs an LLM agent that can prepare transactions and ask the user to confirm them. In-policy actions can be signed by a session-scoped secp256k1 key stored in the macOS Keychain; actions outside the configured policy fall back to explicit Secure Enclave passkey approval. The LLM never has access to the root key, and prompt injection cannot break the spending limits because the Kernel permission enforces the installed policy.

Privacy is treated as a default, not a setting. The wallet runs entirely locally. Helios, the bundler, and the Tor client are compiled into the app binary. The LLM model is downloaded once at first launch and runs on-device. No transaction data, query history, or conversation context leaves the machine except as a signed Ethereum transaction submitted through Flashbots Protect over Tor. There are no external services, no hosted APIs, and no telemetry.

The smart accounts are Kernel ERC-4337 contracts with a WebAuthn validator that verifies P-256 signatures on-chain via the EIP-7951 precompile for root/passkey operations. Session-key operations use Kernel permission data approved by that root key and remain bounded by the installed policy. The stack is built in Rust with a Swift layer for Secure Enclave access on macOS. The Rust core is platform-agnostic and the security adapter layer is the only thing that changes per operating system.

| Principle | How it is expressed in this design |
| :---- | :---- |
| Hardware root of trust | P-256 key generated in Secure Enclave. Never in RAM. No seed phrase. Software compromise cannot extract it. |
| Bounded agent autonomy | Session key bounded by on-chain spending policy. Out-of-policy actions fall back to Secure Enclave passkey approval. |
| Privacy by default | Everything local. Helios, bundler, Tor compiled in. Flashbots Protect over Tor for submission. No external services. |
| Honesty about limits | Session key and bundler key in Keychain are extractable by kernel exploit. Builder sees UserOperation calldata. Both documented explicitly. |
| Minimal attack surface | Custom bundler, no third-party bundler code. LLM agent is untrusted. Prompt injection bounded at contract level. Supply chain controls on every dependency. |
| Self-enclosed operation | No hosted LLM, no paymaster, no external bundler. Only outbound data: signed Ethereum transactions and verified RPC queries. |

| Scope Ethereum only. Multi-chain support is explicitly out of scope for Phase 1\. Self-enclosed by design \- no external services required or offered. Helios, Tor (arti), and the custom bundler are compiled into the app binary. Only the LLM model weights are downloaded at first launch. Helios is embedded via its Rust SDK, not run as a subprocess. |
| :---- |

# **1\. Threat Model**

All security decisions map to one or more of the following threat vectors.

| Threat | Description | Priority |
| :---- | :---- | :---- |
| Prompt injection via LLM | Malicious input tricks agent into exfiltrating keys or authorizing bad transactions | Critical |
| Memory scraping | Key extracted from RAM during the signing window | High |
| Malicious process access | Other apps reading signing module process memory | High |
| Storage compromise | Encrypted key file read from disk | High |
| Supply chain attack | Malicious Cargo dependency exfiltrates key material | High |
| Network privacy | External RPC, bundler, or LLM provider sees transaction data or IP | High |
| Side-channel attacks | Timing or cache attacks against crypto operations | Medium |
| Smart contract bug | Vulnerability in Kernel account contract logic | Medium |
| Cold boot attack | RAM dump after power loss captures key material | Medium |
| Kernel exploit | Full OS compromise \- hardware boundary is the only answer | Low (accepted) |

# **2\. Self-Enclosed Architecture**

The wallet runs entirely locally by default. No external service is required to send transactions, check balances, or run the LLM agent. Every external dependency has a local alternative that is the default.

## **2.1 External dependency map**

| Dependency | Default (local) | Opt-in (external) |
| :---- | :---- | :---- |
| Ethereum RPC | Helios light client \- verifies all responses cryptographically | User's own node or private RPC provider |
| ERC-4337 Bundler | Custom bundler running as local process \- starts on wallet open, stops on close | Local only. No external bundler option at any point. |
| Gas paymaster | User pays own gas always | None offered \- gas sponsorship requires external trust |
| LLM inference | Small model weights downloaded on first launch, runs locally | Only runtime download. User can load any locally installed model. No hosted option. |
| Tor | arti Rust crate compiled into app binary | No subprocess, no binary download, protected by build-time supply chain. |
| Price feeds | On-chain Chainlink via Helios-verified RPC \- free contract read | N/A \- already the default |
| Token metadata | Static bundled registry (top 500 tokens, updated each release) | Contract read for unknown tokens via Helios RPC |

| Design principle The only data that leaves the machine is Ethereum transactions (via Flashbots) and RPC queries (via Helios). All RPC responses are cryptographically verified. The Flashbots builder sees the handleOps() calldata including the UserOperation before on-chain inclusion \- this is the honest limit of pre-inclusion privacy. Tor hides the IP. The on-chain record is permanent and public unless Aztec is used. |
| :---- |

## **2.2 Helios light client**

Helios is embedded via its Rust SDK directly into the wallet binary at compile time \- not downloaded at runtime, not run as a subprocess. It syncs to chain tip in seconds and cryptographically verifies all chain data against block headers. It is protected entirely by the build-time supply chain controls in section 13\.

**First launch flow:**

* Helios Rust SDK compiled into the wallet binary at build time \- not downloaded at runtime

* Helios syncs to chain tip \- takes seconds, not hours

* Wallet points all RPC calls at local Helios instance

* Helios connects to public RPC endpoints for raw data, rotated per-session to prevent query profiling

* All responses verified against cryptographic block headers \- RPC cannot lie or manipulate data

* User can optionally point Helios at their own full node for maximum privacy

**RPC rotation strategy:**

* Default: random selection from curated list of public RPC endpoints per session

* No single endpoint sees full transaction history

* Optional: single configured private RPC (user's own node, Chainstack, Ankr)

* Never: a fixed single public RPC that profiles all activity

## **2.3 Local bundler**

The ERC-4337 bundler is a custom implementation written in Rust, compiled directly into the app binary. There is no external bundler option and no third-party bundler code. The bundler does one job: simulate a UserOperation, build a signed handleOps() transaction, and submit it via Flashbots Protect over Tor.

| Why a custom bundler Open source bundlers come with large dependency trees built for general use cases. This wallet needs a bundler that does exactly one thing: simulate a UserOperation, build a handleOps() transaction, sign it, and submit via Flashbots. A purpose-built Rust implementation has zero unnecessary dependencies, fits inside the existing supply chain controls, and can be fully audited. Every line is owned. |
| :---- |

**Correct ERC-4337 flow:**

* Wallet creates a UserOperation, signed by the session key or root key

* Bundler receives the UserOperation

* Bundler simulates via simulateValidation() against Helios-verified chain state

* Bundler builds a standard Ethereum transaction calling EntryPoint.handleOps()

* Bundler signs that transaction with the funded sender EOA (secp256k1, per-account, Keychain-stored)

* Signed handleOps() transaction submitted to Flashbots Protect RPC over Tor

* Flashbots builder receives a normal signed Ethereum transaction \- not a raw UserOperation

* The UserOperation is inside the handleOps() calldata \- the builder can read it before on-chain inclusion

**Failure and retry behavior:**

* Default: private submission only via Flashbots Protect

* If not included after 25 blocks: wallet prompts user to retry with higher fees

* No automatic public mempool fallback \- user makes that choice explicitly

* If user chooses public submission: clear warning that transaction becomes visible to MEV bots

| Honest privacy note on Flashbots The UserOperation is inside the handleOps() calldata. The Flashbots builder can read the UserOperation contents before on-chain inclusion. Tor hides your IP. Hash-only hints limit metadata shared with searchers. But the builder itself sees the full transaction. This is the honest limit of pre-inclusion privacy without a fully encrypted mempool. |
| :---- |

## **2.4 LLM privacy tiers**

LLM inference runs entirely locally. The model weights are the only runtime artifact downloaded after installation \- they are too large to ship in the app binary. A default model is downloaded on first launch. Users can switch to any locally installed model. There is no hosted API option. All other runtime dependencies (Helios, bundler, Tor) are compiled into the app binary.

| Option | Setup | Notes |
| :---- | :---- | :---- |
| Default model (always) | Small quantized model downloaded on first launch | Runs locally, no external calls ever, suitable for routine wallet operations |
| User-selected local model | User points wallet at any locally installed model | Full privacy maintained, user responsible for model capability |

## **2.5 Full local architecture diagram**

┌──────────────────────────────────────────────────┐

│         Wallet App           │

│                         │

│ ┌────────────────┐  ┌────────────────────┐  │

│ │  LLM Agent  │  │  SwiftUI / Tauri │  │

│ │ (local model) │  │    UI     │  │

│ └───────┬────────┘  └────────────────────┘  │

│     │ tool call: sign\_transaction      │

│ ┌───────▼──────────────────────────────────┐  │

│ │     Signing Module (XPC)       │  │

│ │ policy engine · session key mgmt    │  │

│ │ user key · enclave access        │  │

│ └───────┬──────────────────────────────────┘  │

│     │                    │

│ ┌───────▼──────┐ ┌────────────────────────┐  │

│ │Local Bundler │ │ Helios Light Client  │  │

│ │(Custom  │ │ verifies all RPC data │  │

│ │Bundler) │ │                        │  │

│ └───────┬──────┘ └───────────┬────────────┘  │

└──────────┼─────────────────────┼────────────────┘

      │           │ verified queries

      └──────────┬──────────┘

           │

        Ethereum mainnet

     (rotated public RPCs or own node)

# **3\. Account Model \- Kernel Smart Accounts (ERC-4337)**

## **3.1 Why Kernel smart accounts**

A traditional EOA is controlled by a secp256k1 private key that exists in software \- in RAM, on disk, or derivable from a seed phrase. Compromise or extraction is a realistic threat. This architecture replaces the EOA with a P-256 key generated inside the Secure Enclave that cannot be extracted by any software path, including kernel exploits. The root key is hardware-bound. Software-based key compromise is eliminated by design, not just mitigated.

| Property | EOA | Kernel Smart Account (this architecture) |
| :---- | :---- | :---- |
| Root key extractable | Yes \- secp256k1 exists in RAM or on disk, derivable from seed phrase | No \- P-256 key generated inside Secure Enclave, cannot be extracted by any software path including kernel exploits |
| Root key compromise via software | Realistic threat | Eliminated by hardware design |
| Session key compromised | N/A \- no session keys | Bounded by spending limits, timers, and on-chain `validUntil`. Damage is contained and time-limited. |
| Device loss without recovery module | Seed phrase covers this | Funds permanently inaccessible \- recovery module is the mitigation |
| Programmable rules | None | Spending limits, timelocks, contract whitelists |
| Key rotation without moving funds | Impossible | Possible \- replace authorized signer |
| LLM agent integration | Agent needs direct key access | Agent uses a bounded session key for approved in-policy actions; passkey approval remains the fallback |
| Permission plugin cost | N/A | No standalone enable transaction; permission install data can be bundled with the first session UserOperation |

## **3.2 Session signing architecture**

| Property | User Key (per-account owner) | Session key (assistant signing path) |
| :---- | :---- | :---- |
| Purpose | Owner of each individual Kernel account | Approved transfer and swap actions inside the active session policy |
| Storage | Secure Enclave P-256 (CryptoKit) | macOS Keychain generic password, secp256k1, scoped by chain and account |
| Access control | biometryCurrentSet \- Touch ID required | None \- silent reads by signing module. No Touch ID. |
| Authorization | Permanent signer on Kernel contract | Passkey-signed enable digest plus Kernel permission data |
| On-chain registration | Yes \- permanent | Lazily installed with the first session-signed UserOperation, then reused until expiry or revoke |
| Spending authority | Unlimited | Bounded by session authorization policy |
| Lifespan | Permanent until explicitly rotated | Session-scoped; persisted while active, deleted on local expiry or revoke |
| Gas cost to rotate | Small on-chain tx | No standalone enable tx; first session UserOperation carries enable data. Revoke is an on-chain UserOperation. |
| Compromise blast radius | Not applicable \- P-256 key is hardware-bound, software extraction impossible | Capped at session spending limit, expires automatically |

## **3.3 On-chain spending policy**

Spending rules are encoded in the Kernel permission data approved by the root key. The app stores that session record locally, and the first in-policy session-signed UserOperation can install the permission on-chain in enable mode. Once installed, later in-policy UserOperations use the installed permission mode. Rules cannot be bypassed by the LLM, UI, or signing module.

**Example session authorization:**

SessionPermissionConfig {

  account: Kernel account address

  chainId: active chain

  sessionKey: session secp256k1 signer address

  validUntil: now \+ session duration

  gasBudgetWei: 0.05 ETH default

  rateLimitCount: 20 default

  rateLimitIntervalSec: 24h default

  allowedCalls: [

    native ETH transfer up to per-action ETH cap when enabled

    known ERC-20 transfer up to per-token cap

    known ERC-20 approve up to per-token cap, SwapRouter02 only by default

    Uniswap SwapRouter02 exact-input swap with recipient and amount rules

  ]

}

// Enable digest signed by user key (Touch ID)

// Permission installed lazily by the first in-policy session UserOperation

// Kernel validates policy at every UserOperation execution

| Prompt injection boundary A fully successful prompt injection that compromises the LLM agent is still bounded by the active session policy. The attacker cannot exceed per-action token caps, rate limits, gas budget, timer bounds, or allowed contract/function rules. Actions outside policy fall back to passkey approval instead of session signing. |
| :---- |

# **4\. Key Architecture**

## **4.1 Three keys, three roles**

The wallet uses three distinct keys with different roles, storage locations, and threat profiles. The architecture is designed so that the only key that can authorize fund movement is permanently inside hardware silicon.

| Key | Type | Storage | Role | Extractable |
| :---- | :---- | :---- | :---- | :---- |
| User root key | P-256 (secp256r1) | Secure Enclave (CryptoKit) | Signs UserOperations, authorizes account changes, recovery root | No \- hardware enforced |
| Session key | secp256k1 | macOS Keychain (same storage class as bundler key) | Approved assistant transactions within session policy | Yes \- bounded by on-chain spending policy |
| Bundler operator key | secp256k1 | macOS Keychain | Signs handleOps() wrapper tx to pay gas | Yes \- but can only drain gas float, not funds |

| Key insight: only the root key controls unrestricted authority The bundler key signs the Ethereum transaction that submits the bundle but cannot authorize any UserOperation. An attacker who steals the bundler key can drain only the gas float. The Secure Enclave root key approves account ownership and session permissions; session-key UserOperations are bounded by Kernel policy. No secp256k1 EOA has unrestricted authority over the Smart Account. |
| :---- |

## **4.2 User root key \- secure enclave P-256**

The root key is a P-256 key pair generated and permanently stored inside the macOS Secure Enclave using CryptoKit. It is the user's only signing identity. It never exists in RAM, never crosses any software boundary, and cannot be exported by any API. Touch ID is required for every signing operation.

| Property | Guarantee |
| :---- | :---- |
| Key generation | Inside the Enclave. The private key scalar never exists outside it. |
| Signing | Occurs inside the Enclave. The app sends the hash. The Enclave returns (r, s). |
| Export | Impossible by hardware design. No API exists to retrieve the private key. |
| OS compromise | Protected. Root access cannot extract Enclave keys. |
| Physical attack | Protected against standard extraction techniques. |
| User presence | Touch ID required for every signing operation. Cannot be bypassed in software. |
| Curve | P-256 (secp256r1). Same curve as WebAuthn and passkeys. |
| iCloud sync | Disabled. CryptoKit SecureEnclave keys are device-bound at the hardware level. |

**Why CryptoKit and not the WebAuthn API:**

CryptoKit's Secure Enclave API operates one layer below the standard WebAuthn path. It generates a P-256 key pair inside the Enclave and returns a raw (r, s) signature with no ceremony fields, no domain binding, and no mechanism to export or transmit the private key scalar. The WebAuthn ceremony fields required by the on-chain verifier (authenticatorData, clientDataJSON) are constructed manually in Rust following the Daimo specification. The on-chain contract verifies that sha256(authenticatorData || sha256(clientDataJSON)) is a valid P-256 signature under the registered public key \- a check that holds regardless of construction path. CryptoKit is chosen because it provides the hardware boundary guarantee without any cloud backup path.

**No seed phrase:**

There is no mnemonic, no exportable root secret, and no BIP-32 derivation. The private key scalar is computed inside the Enclave and never leaves it. There is no moment in the key generation process where the private key exists in application RAM, on disk, or in any software-accessible memory.

| Security implication of no seed phrase If the root key is lost (device destroyed, Enclave wiped) without a pre-installed recovery module, access to the Smart Account is permanently lost. This is why recovery module setup is mandatory before holding significant value \- it is not optional. The absence of a seed phrase eliminates an entire class of backup theft and phishing attacks. Recovery is handled entirely on-chain. |
| :---- |

**How it signs Kernel transactions:**

* Kernel's WebAuthn validator plugin is installed as the sudo validator at account deployment

* When EntryPoint calls validateUserOp(), Kernel routes to the WebAuthn validator

* Validator verifies the P-256 signature via the EIP-7951 precompile at 0x0000000000000000000000000000000000000100

* EIP-7951 is live on Ethereum mainnet since the Fusaka upgrade (December 2025\) \- approximately 6,900 gas

* secp256k1 is not used for the root key at any point

**Why not EIP-7702:**

EIP-7702 allows an EOA to delegate execution logic to a smart contract. The critical issue is that the secp256k1 EOA key remains the ultimate authority at all times. It can remove the delegation, transfer ETH directly without smart account validation, and bypass the passkey, session key policy, and every on-chain module. Whoever holds the raw EOA key holds unconditional control with no biometric check and no spending limit. This reintroduces the private key problem this architecture is designed to eliminate. ERC-4337 with a Kernel account and Secure Enclave passkey satisfies the unextractable root of trust requirement. EIP-7702 does not.

| Property | ERC-4337 \+ Kernel (chosen) | EIP-7702 (rejected) |
| :---- | :---- | :---- |
| Root key type | P-256 (Secure Enclave) | secp256k1 (software) |
| Root key in RAM | Never | Yes (\~200 microseconds if sealed) |
| Root key extractable | No \- hardware boundary | Yes \- kernel exploit |
| Seed phrase required | No | Yes |
| Smart account bypass | Not possible | Yes \- via raw EOA key |
| First-use gas cost | \~200k gas (deployment) | \~25k gas (delegation tx) |

## **4.3 Session key and session permissions \- macOS Keychain**

The session key is a secp256k1 secret stored in the macOS Keychain as a generic password. It is scoped by chain and Kernel account address, and it signs UserOperations only when the active intent is inside the saved session policy. The app creates the key when the user enables session keys for a deployed account, stores a passkey-approved permission record locally, and deletes the key when the session expires locally or revoke is confirmed.

| Property | Value |
| :---- | :---- |
| Storage | macOS Keychain, kSecClassGenericPassword |
| Accessibility | kSecAttrAccessibleWhenUnlockedThisDeviceOnly |
| Access control | None \- silent reads by signing module. No Touch ID. |
| Curve | secp256k1 |
| Lifespan | Session-scoped \- persists while the local session record is active, then deleted on expiry or revoke |
| Autonomous operation | Yes for approved in-policy transfer and swap actions |
| If compromised | Attacker bounded by on-chain spending policy. Key expires at session end. |

**Enable session keys:**

* App requires the Kernel account to be deployed

* App creates or reads the account-scoped session key from Keychain

* App reads Kernel `currentNonce`

* App builds Kernel permission config JSON, enable data, selector data, default nonce key, and enable-mode nonce key

* Root key (Touch ID) signs the permission enable digest

* App stores the session record locally and marks session signing enabled

* No standalone enable transaction is sent. The first approved in-policy action installs the permission on-chain in enable mode.

**During session:**

* Chat or slash command produces a transfer or swap intent

* App mirrors the session policy locally. If the intent is outside policy, missing data, expired, inactive, or pending revoke, the app falls back to passkey approval

* In-policy intent uses the session key silently from Keychain

* First session-signed UserOperation uses enable mode and carries enable data, selector data, and enable signature

* Later session-signed UserOperations use installed mode after the install receipt is observed

* Swap UserOperations can include ERC-20 approval calls before the swap when allowance is missing

* Bundler signs handleOps() transaction and submits via Flashbots Protect over Tor

* Only submitted UserOperations cost gas. Session enable is bundled with the first in-policy action, not sent as a separate transaction.

**Session end or revoke:**

* Local expiry removes the session record, disables local session signing, and deletes the Keychain session secret

* On-chain `validUntil` is the fallback boundary if the app does not clean up local state

* Explicit revoke submits a passkey-signed UserOperation that uninstalls the Kernel permission, then clears local session state after receipt

| Expiry Mechanism | What it does | Trigger |
| :---- | :---- | :---- |
| Keychain deletion | App cannot read the local session key, so silent signing stops. | Local duration or inactivity expiry |
| Permission timestamp | Kernel rejects expired session UserOperations after `validUntil`. | Session duration passes |
| Local policy mirror | App refuses session signing and falls back to passkey before submission. | Intent is outside configured policy |
| Permission uninstall | Kernel permission is removed on-chain. | User explicitly revokes |

## **4.4 Bundler operator key \- macOS Keychain**

The bundler key is a secp256k1 key stored in the macOS Keychain. It signs the Ethereum wrapper transaction that submits the UserOperation bundle to the EntryPoint. It is a liveness key, not a security key.

| Property | Value |
| :---- | :---- |
| Storage | macOS Keychain, kSecClassGenericPassword |
| Accessibility | kSecAttrAccessibleWhenUnlockedThisDeviceOnly |
| Access control | None (no SecAccessControl). Silent reads by app when screen unlocked. |
| iCloud sync | Disabled (ThisDeviceOnly). Never leaves the machine. |
| Curve | secp256k1 |
| Rust access | security-framework crate |
| OS compromise | Can be extracted by kernel-level attacker. Accepted risk \- see below. |
| Impact if stolen | Attacker can drain gas float only. Kernel account funds unaffected. |

| Why Keychain risk is accepted for the bundler key The Keychain uses software encryption \- a kernel exploit could extract it. This is accepted because the consequence is bounded: the attacker gains control of a small gas float (e.g. 0.05 ETH), not the Smart Account. The Kernel WebAuthn validator enforces that UserOperation authorization requires a P-256 Secure Enclave signature. The bundler key cannot authorize any fund movement regardless of whether it is compromised. |
| :---- |

# **5\. Process Architecture**

## **5.1 Three-tier isolation model**

The system is split into three independent process tiers. A compromise in any single tier does not cascade upward to key material. The LLM agent is explicitly untrusted \- it processes external input and may be subject to prompt injection.

┌──────────────────────────────────────────┐

│      LLM Agent Process       │ UNTRUSTED

│ reasons · plans · calls tools      │ processes external input

│ never sees any key material       │ prompt injection possible

└─────────────────┬────────────────────────┘

         │ tool call: sign\_transaction(tx)

         │ (validated \+ sanitized in signing module)

         ▼

┌──────────────────────────────────────────┐

│    Signing Module (XPC Service)    │ RESTRICTED

│ enforces session spending policy    │ network: NONE

│ manages session key permission lifecycle  │ file: account-scoped key path

│ unwrap → sign → zero → return sig only │ no external calls ever

└─────────────────┬────────────────────────┘

         │ if above limit: escalate to user

         ▼

┌──────────────────────────────────────────┐

│   User Signing (XPC \+ Secure Enclave) │ MOST TRUSTED

│ Touch ID biometric gate         │ entitlements: minimal

│ user key unwrap \+ sign         │ network: NONE

└─────────────────┬────────────────────────┘

         │

      Secure Enclave

      (root P-256 key only \- never exported, never in RAM)

## **5.2 XPC message contract**

Every message crossing a process boundary is treated as untrusted. The signing module validates and sanitizes all inputs from the LLM agent before acting.

| Message | From → To | Contains | Never Contains |
| :---- | :---- | :---- | :---- |
| sign\_transaction | LLM Agent → Signing Module | Unsigned tx, recipient, amount, token | Any key material |
| signature\_result | Signing Module → LLM Agent | Signature bytes only | Key, wrapped key, session state |
| escalate\_to\_user | Signing Module → UI | TX details for user display | Key material |
| user\_approved | UI → Signing Module | Approval boolean \+ Touch ID result | Key material |
| session\_start | UI → Signing Module | Session config, spending limits | Nothing sensitive |
| session\_end | UI → Signing Module | Session close signal | Triggers enclave key deletion |
| session\_start | UI \- Signing Module | Session config, spending policy | Nothing sensitive |

# **6\. Rust Core Library**

## **6.1 Philosophy**

The Rust core is the permanent, platform-agnostic investment. All security-critical logic lives here. Frontends and platform adapters are pluggable. Never coupled to Swift or macOS-specific APIs.

## **6.2 Core API surface**

trait KeyStore {

  fn sign\_user(\&self, tx\_hash: &\[u8\]) \-\> Result\<Signature\>;

  fn sign\_session(\&self, tx\_hash: &\[u8\]) \-\> Result\<Signature\>;

  fn install\_permission\_plugin(\&self, config: SessionConfig) \-\> Result\<()\>;

  fn revoke\_permission\_plugin(\&self) \-\> Result\<()\>;

}

trait PolicyEngine {

  fn check(\&self, tx: \&Transaction, auth: \&SessionAuth) \-\> PolicyResult;

  // PolicyResult: Approve | Reject | EscalateToUser

}

trait SessionManager {

  fn open(\&self, config: SessionConfig) \-\> Result\<SessionAuth\>;

  fn close(\&self) \-\> Result\<()\>;

}

// Platform KeyStore implementations:

struct AppleSecureEnclave;  // macOS / iOS \- Phase 1

struct LinuxTPM;       // Linux TPM 2.0 \- Phase 3

struct SoftwareFallback;   // Argon2id-derived \- no hardware

## **6.3 Cross-platform strategy**

| Platform | Security Adapter | Key Protection | Timeline |
| :---- | :---- | :---- | :---- |
| macOS | Apple Secure Enclave (CryptoKit) | P-256 root key directly in Enclave \- Model 1, signs via WebAuthn validator \+ EIP-7951 | Phase 1 |
| iOS | Apple Secure Enclave (CryptoKit) | Same as macOS \- shared Swift layer | Phase 2 |
| Linux | TPM 2.0 via tpm2-tools | Hardware if TPM present | Phase 3 |
| Linux (no TPM) | SoftwareFallback | Argon2id-derived wrapping key | Phase 3 |
| Windows | TPM 2.0 via Windows CNG | Hardware TPM-backed | Phase 4 |

# **7\. Backup and Recovery**

There is no seed phrase in this architecture. The root key is generated inside the Secure Enclave and never exists in recoverable form. Recovery depends entirely on a pre-installed on-chain recovery module. Without one, device loss means permanent fund loss.

## **7.1 Recovery scenarios**

| Scenario | Recovery Path | Outcome |
| :---- | :---- | :---- |
| Device lost or stolen \- recovery module installed | Guardian approval on new device | Full recovery \- new P-256 Enclave key installed as owner via recovery module |
| Device lost or stolen \- no recovery module | None | Funds permanently inaccessible. No seed phrase exists. This is why recovery module setup is mandatory. |
| Device destroyed \- recovery module installed | Guardian approval on new device | Full recovery \- same as above |
| Device destroyed \- no recovery module | None | Funds permanently inaccessible. |
| Enclave corrupted, device works \- recovery module installed | Guardian approval, rotate signer | Full recovery \- new Enclave key installed as owner |
| Enclave corrupted, no recovery module | None | Funds permanently inaccessible. |

| Recovery module is the critical backup There is no seed phrase. The Kernel contract holds funds and the device holds the root P-256 key. Device failure is recoverable only if a recovery module was installed before the loss. The recovery module \- not a seed phrase \- is the only backup mechanism. Installing it at account creation is mandatory for anyone holding significant value. |
| :---- |

## **7.2 User guidance at setup**

Shown once at wallet creation. Clear, short, no false reassurance.

Your wallet key lives inside this device Secure Enclave.

It cannot be exported, backed up, or recovered from any phrase.

If you lose this device without a recovery module, your funds are gone.

Set up a recovery module before holding significant value.

## **7.3 Future consideration: social recovery**

Kernel supports recovery modules. Phase 1 ships with basic recovery module setup that users must configure before holding significant value. Without it, device loss means permanent fund loss. The module is installed at account creation \- the UX strongly encourages this. Full guardian-based social recovery UX is a Phase 2 feature.

# **8\. Multi-Account Architecture**

Each account is a separate Kernel smart contract with its own independent Ethereum address, balance, and spending policy. All accounts share the same Secure Enclave P-256 root key as their owner. Accounts are separated by contract address (CREATE2 with unique salt per account), not by key. Root key compromise affects all accounts.

## **8.1 Key and address structure**

Secure Enclave P-256 root key  (one key, owner of all accounts)

   |

   \+-\> Kernel contract A   0x111...  (CREATE2 with salt 0\)

   \+-\> Kernel contract B   0x222...  (CREATE2 with salt 1\)

   \+-\> Kernel contract C   0x333...  (CREATE2 with salt 2\)

No BIP-32 derivation. One Enclave key is the P-256 WebAuthn owner of all accounts.

Account separation is by Kernel contract address, not by key.

* Each Kernel contract has a completely independent on-chain address

* All accounts share the same P-256 Enclave root key as owner \- separation is by contract address

* Enclave root key is not visible on-chain \- only the P-256 public key registered in the Kernel WebAuthn validator

* Addresses are deterministic via CREATE2 \- known before deployment

* Contracts deploy automatically on first outgoing transaction \- no upfront gas

* Undeployed accounts can still receive funds \- balance queryable at address

## **8.2 Session key across accounts**

* One session key record per chain and Kernel account address

* Each Kernel contract enforces its own spending policy independently

* The session key is the signer within a Kernel permission \- per-account limits are encoded in that permission

* An account can disable native transfers, ERC-20 transfers, approvals, or swaps independently

| Per-account policy is the source of truth The app stores a policy snapshot in each session record and mirrors it before signing. The Kernel permission is the on-chain enforcement boundary once installed. Editing policy affects the next session-key enable flow; actions outside the current snapshot fall back to passkey approval. |
| :---- |

## **8.3 Account creation**

* Explicit \- user intentionally creates a new account, not automatic

* User assigns a name and configures spending policy at creation

* Wallet computes next CREATE2 address using a unique salt \- no key derivation

* Address is available immediately for receiving \- no gas required yet

* Contract deploys on first outgoing transaction automatically

**Example account types:**

| Account | Session Signing Authority | Use Case |
| :---- | :---- | :---- |
| Daily | Moderate token caps and session duration | General assistant operations |
| DeFi | Higher token caps, router-limited approvals and swaps | DeFi interactions via assistant |
| Savings | None \- user key required for everything | Long-term holdings, maximum security |
| Business | Separate limits and whitelist | Separate on-chain identity and history |

## **8.4 Restore and account discovery**

There is no mnemonic and no BIP-32 derivation. The Secure Enclave root key is device-bound by hardware. Restore on a new device requires the recovery module. Account addresses are recovered via guardian approval flow. Funds and on-chain security state are always recoverable if the recovery module was installed.

**Discovery flow (new device via recovery module):**

* Recovery module guardian flow authorizes new P-256 Enclave key on existing accounts

* Account addresses from encrypted local backup or user-provided

* For each known address: query Helios for deployed bytecode and on-chain state

* Read installed modules, policy version, and signer set from Kernel contract

* Balances and transaction history recoverable from chain

* Local metadata (names, labels) recoverable only if encrypted metadata backup exists

**What the user sees:**

Recovery module guardian approval received.

Reconnecting to existing accounts...

Account 1   0x111...   2.4 ETH    Kernel v3, policy v3

Account 2   0x222...   0.8 ETH    Kernel v3, policy v1

Account 3   0x333...   150 USDC   Kernel v3, policy v2

New Enclave key installed as owner. Rename accounts to continue.

| Privacy note All accounts share one P-256 Enclave root key as owner. Account separation is by contract address only \- the root key itself is not visible on-chain. Behavioral analysis across accounts is possible if both addresses are shared publicly with the same counterparties \- this is true of any multi-account wallet. |
| :---- |

# **9\. Session Policy, Spending Limits, and Transaction Privacy**

## **9.1 Session policy and passkey fallback**

The session key signs only actions inside the active policy snapshot. Anything outside the policy uses the passkey path, which asks the user for Secure Enclave approval and signs with the root key. The current app implements fallback rather than a two-signature co-signature flow.

| Policy knob | Default | Enforcement |
| :---- | :---- | :---- |
| ETH transfers | Enabled, 0.1 ETH per action | Native transfer value and ETH input sent to SwapRouter02 |
| ERC-20 transfers | Enabled for known token list | Per-token transfer amount cap |
| ERC-20 approvals | SwapRouter02 only | Approval spender and approval amount cap |
| Swaps | Enabled for known Uniswap SwapRouter02 addresses | Router, recipient, input amount, and token scope |
| Rate limit | 20 actions per 24h | Local mirror before signing and Kernel permission data |
| Gas budget | 0.05 ETH | Kernel permission data |
| Session duration | 8h default, 4h to 24h options | Local expiry plus on-chain `validUntil` |
| Inactivity timeout | 1h default, 10m to 4h | Local session cleanup |

* ETH transfers: permitted only when enabled and under the ETH cap

* NFT transfers: never permitted for session key regardless of policy

* New contract interactions: never permitted for session key regardless of policy

* Contract whitelist: known local token registry plus known Uniswap SwapRouter02 addresses

* Disabled policy surfaces: passkey approval required

## **9.2 Pre-inclusion privacy: Flashbots Protect**

Flashbots Protect is the default transaction submission path. It routes transactions through a private mempool, preventing frontrunning and sandwich attacks before a transaction is included in a block. Free, requires no registration, and is strictly better than the public mempool for users.

| Property | Public Mempool | Flashbots Protect |
| :---- | :---- | :---- |
| Frontrunning protection | None \- all bots see tx immediately | Full \- tx hidden until block inclusion |
| Sandwich attack risk | High | Eliminated |
| MEV refunds | None | Up to 90% of generated MEV returned to user |
| Failed tx cost | Full gas paid | Zero \- reverted txs are not included |
| IP privacy | Your IP visible to RPC | Tor support built in \- IP hidden |
| Cost | Free | Free |
| Inclusion speed | Next block typical | 97%+ included within 3 blocks |

**Why Flashbots Protect over MEV blocker:**

* MEV Blocker shares full transaction details with searchers to maximize refunds \- lower privacy

* Flashbots Protect allows configuring exactly what is revealed \- set to hash-only for maximum privacy

* Flashbots has native Tor support \- MEV Blocker does not

* Flashbots has higher reliability: 98.5% success vs 96.2% for MEV Blocker

**Integration:**

* Local bundler signs a handleOps() transaction with the funded sender EOA and submits it to Flashbots Protect RPC over Tor

* Hint setting: hash-only \- maximum privacy, minimum tx detail revealed to searchers

* No registration, no API key, no persistent relationship with Flashbots

* One-shot per transaction \- Flashbots sees a tx that will be public on-chain in seconds

# **10\. Session Duration Policy**

Two independent timers run concurrently. Whichever fires first ends local session signing. The app removes the local session record and deletes the Keychain session key when it observes expiry. The Kernel permission's `validUntil` timestamp is the on-chain fallback, so expired session UserOperations are rejected even if local cleanup did not run.

## **10.1 Timer configuration**

| Timer | Default | User Range | Adjustable |
| :---- | :---- | :---- | :---- |
| Session duration | 8 hours | 4h / 8h / 12h / 16h / 20h / 24h | Yes \- fixed steps |
| Inactivity timeout | 1 hour | 10 minutes to 4 hours | Yes \- any value in range |

| Rule: whichever fires first ends the session A 24h session with a 10min inactivity timeout ends after 10 minutes of no activity. A 4h session with a 2h inactivity timeout ends after 4h regardless of activity. The UI enforces that inactivity timeout cannot exceed session duration. |
| :---- |

## **10.2 What resets the inactivity timer**

| Action | Resets Timer |
| :---- | :---- |
| UI interaction \- any user input | Yes |
| Session-key signing a transaction | Yes |
| Background price feed update | No |
| Passive balance or state check | No |
| Network sync via Helios | No |

## **10.3 Session end behavior**

* Local session record is removed and local session signing is disabled

* Keychain session key is deleted

* Assistant actions outside a new active session require passkey approval

* UI shows session expired prompt

* New session requires Touch ID to approve a fresh session permission; first in-policy action installs it on-chain if needed

# **11\. UI and Platform Architecture**

## **11.1 Phase 1: native macOS**

SwiftUI with XPC process isolation. No Tauri. The macOS security model is the strongest available on any desktop platform for this use case and giving it up for UI portability is the wrong tradeoff for a security-first wallet.

| Why not Tauri for phase 1 XPC is the strongest part of the macOS security model for this wallet. It provides genuine OS-enforced process isolation between the UI and the signing module. Tauri's IPC bridge is not equivalent \- it is message passing without the same sandbox enforcement. For a privacy-first wallet, giving up XPC for UI convenience is the wrong tradeoff. |
| :---- |

**macOS security stack:**

* SwiftUI \- UI layer, sandboxed, no key access

* XPC \- OS-enforced process isolation between UI and signing module

* App Sandbox \- entitlements restrict file system, network, hardware access

* Hardened Runtime \- prevents code injection and dylib hijacking

* Secure Enclave \- hardware key protection via CryptoKit

## **11.2 Future: Linux native**

Linux native is achievable at equivalent security to macOS but requires significantly more deliberate configuration. macOS does process isolation automatically via XPC. Linux makes you build it yourself with D-Bus, seccomp, and namespaces. Getting it right is a separate engineering problem that deserves focused attention, not a quick port.

**Linux security stack (when built):**

* GTK or Qt \- native UI layer

* D-Bus with policy files \- IPC between UI and signing process

* Seccomp profile \- syscall whitelist for signing process

* Linux namespaces \- network, filesystem, pid isolation

* Systemd unit \- privilege dropping for signing service

* TPM 2.0 via tpm2-tools \- hardware key protection where available

| Property | macOS XPC | Linux D-Bus \+ seccomp |
| :---- | :---- | :---- |
| Process isolation | OS-enforced automatically | Manual \- seccomp \+ namespaces |
| IPC sandboxing | Built into XPC | D-Bus policy files \- manual configuration |
| Privilege dropping | Automatic per XPC service | Systemd unit configuration |
| Attack surface if misconfigured | Small \- OS has safe defaults | Large \- every decision is yours |
| Audit complexity | Low | High |
| Security ceiling | High | Equivalent \- but more work to reach it |

## **11.3 Tauri: later decision**

Tauri is not ruled out for future platforms. If it matures sufficiently or the signing module is kept as a separate native process communicating with the Tauri app, the architecture holds. The key constraint: the signing module is never inside the Tauri webview process. The Rust core does not care what sits above it. This decision is deferred until Linux or Windows expansion is actively planned.

# **12\. Supply Chain Security**

Every dependency in the build is third-party code running inside the security boundary with full access to process memory. A malicious or compromised crate that touches key material is catastrophic. Four measures address this.

## **12.1 Critical dependency surface**

These five crates directly touch key material. They are the highest-priority audit targets and the primary supply chain risk.

| Crate | Role | Risk if Compromised |
| :---- | :---- | :---- |
| k256 | secp256k1 signing | Signs transactions with attacker-controlled key or leaks key |
| zeroize | Memory zeroing after use | Skips zeroing \- key material persists in RAM |
| subtle | Constant-time operations | Introduces timing side-channel \- key bits leaked |

## **12.2 Mitigations**

**1\. cargo.lock committed and enforced**

* Every dependency pinned to an exact content hash

* A compromised crate version cannot enter the build without an explicit code change

* CI rejects any build where Cargo.lock is out of sync with Cargo.toml

**2\. cargo-audit in CI**

* Every build checked against the RustSec advisory database

* Known vulnerable or compromised crates block the build automatically

* No manual step required \- runs on every commit

**3\. cargo-vet for critical crates**

* The five critical crates above are explicitly audited and signed off on

* Any version update to these crates requires a new explicit audit before it enters the build

* Audit attestations are committed to the repo and publicly verifiable

**4\. reproducible builds**

* Rust toolchain version pinned via rust-toolchain.toml

* Same source code produces a bit-for-bit identical binary every time

* Users can verify the binary they downloaded matches the published source

* Catches a compromised build pipeline \- even if CI is hacked, verification still works

* CI pipeline uses minimal permissions \- build and sign only, no broad secrets access

* All GitHub Actions pinned to exact commit SHAs, not version tags

## **12.3 Runtime artifact provenance**

Helios SDK, the local bundler, and the LLM runtime are larger dependencies than typical wallet code. Each expands the attack surface meaningfully and should be audited before launch.

# **13\. Honest Security Limitations**

What the architecture does NOT protect against. Honesty about limitations is a design requirement.

| Limitation | Why | Mitigation / Acceptance |
| :---- | :---- | :---- |
| Session key briefly in RAM at signing | Keychain key read into app memory at signing | Blast radius bounded by per-session permission policy. Local expiry deletes the key, and the Kernel permission expires via `validUntil`. |
| RPC query privacy | Helios verifies correctness but RPC sees your IP and queries | Per-session RPC rotation via Helios, Tor for Flashbots submission |
| Builder sees UserOperation | The handleOps() calldata is readable by the Flashbots builder before inclusion | Tor hides IP. Hash-only hints limit searcher metadata. Builder trust is unavoidable without encrypted mempool (future: Aztec). |
| Kernel-level OS compromise | Session key and bundler key in Keychain can be extracted by a kernel exploit. Root P-256 key in Secure Enclave is protected even from kernel exploits. | Session key blast radius bounded by per-session permission policy. Bundler key only loses gas float. Root key hardware-protected. Accepted residual risk. |
| Smart contract vulnerability | Kernel contract could have bugs | Use only audited releases, monitor security advisories |
| Supply chain risk | Cargo dependencies are third-party code | Pin all hashes in Cargo.lock, minimize deps, audit critical crates |
| Timing / side-channel | Rust memory safety is not constant-time | subtle crate, k256 constant-time signing, explicit audit |
| Session key extractable | Session key is secp256k1 in Keychain. OS compromise can extract it. | Accepted. Blast radius bounded by per-session permission policy. Permission plugin expires via `validUntil`. Root P-256 key in Enclave unaffected. |

# **14\. Tech Stack**

| Layer | Technology | Rationale |
| :---- | :---- | :---- |
| Crypto core | Rust | Memory safety, portability, constant-time ecosystem |
| secp256k1 signing | k256 crate | Constant-time, well-audited |
| Memory zeroing | zeroize crate | Compiler-safe zeroing \- prevents optimization removal |
| Constant-time ops | subtle crate | Prevents timing side-channel attacks |
| Policy engine | Rust (custom) | No external deps \- critical path, minimal attack surface |
| Smart account | Kernel (ERC-4337) | Audited, session keys via Kernel WebAuthn validator module, off-chain authorization |
| Session keys | Kernel WebAuthn validator \+ session key plugin | Audited module. Enable data can be bundled into the first session UserOperation; revoke is an on-chain UserOperation. |
| Light client | Helios Rust SDK (compiled into app) | Cryptographic verification, fast sync. Not downloaded at runtime. |
| Local bundler | Custom bundler (Rust, compiled into app) | Localhost only. Compiled in \- not downloaded at runtime. |
| Tor | arti Rust crate (compiled in) | Official Tor Project Rust implementation. No binary download, no subprocess. |
| MEV protection | Flashbots Protect via Tor (arti) | Free, hash-only hints, IP hidden via Tor |
| Local LLM | Small quantized model (first launch download) | Full inference privacy, no hosted option |
| macOS enclave (root key) | CryptoKit SecureEnclave.P256.Signing.PrivateKey | P-256 key never in RAM. Touch ID per op. No export API. Device-bound. |
| macOS keychain (bundler key) | security-framework Rust crate | secp256k1 bundler liveness key. Can only drain gas float if stolen. |
| IPC | XPC (macOS) | OS-enforced process isolation |
| UI \- Phase 1 | SwiftUI (macOS) | Native, best macOS sandbox support |
| UI \- Phase 2+ | Native per OS \- Tauri decision deferred | Rust core unchanged regardless of UI choice |

# **15\. Out of Scope \- Phase 1**

Deferred to later phases. The architecture accommodates all of these without rework.

| Item | Reason Deferred | Path to Add Later |
| :---- | :---- | :---- |
| Seed phrase / mnemonic import | No migration path from existing EOA wallets. Existing wallet users transfer funds to their new Kernel account address via a normal ETH/token transfer. | Migration is not supported by design. The root key is always P-256 generated in the Secure Enclave \- there is no import path for secp256k1 keys. |
| Hardware wallet integration | Significant UX and integration complexity | Add as optional additional Kernel account module \- no architecture changes |
| Full guardian social recovery UX | Phase 2 \- guardian management UX is a product in itself | Basic recovery module setup is mandatory in Phase 1\. Full multi-guardian social recovery UX with guardian management, rotation, and dispute resolution is Phase 2\. |
| Linux sandboxing | D-Bus \+ seccomp requires focused engineering \- not a quick port | D-Bus \+ seccomp \+ namespaces when Linux phase begins |
| Multi-chain support | Simplifies Phase 1 significantly | Rust core is portable, add chain adapters later |
| Windows support | After Linux | TPM 2.0 via Windows CNG, Rust core unchanged |
| HOPR / Nym mixnet | Operational complexity, latency tradeoff | Could layer on top of Helios RPC queries for IP privacy beyond Tor |
| Encrypted metadata backup | Phase 2 feature \- accounts functional without it | Export encrypted blob of account names, labels, ordering. Restore re-imports. Funds and security state recoverable without this. |
| Encrypted mempool | Not production-ready on Ethereum mainnet | Aztec solves this at L2 level. Shutter Network is an alternative for mainnet but early stage. |

# **16\. Resolved Design Decisions**

Closed decisions and reasoning. Do not reopen without strong justification.

| Decision | Choice | Reasoning |
| :---- | :---- | :---- |
| Chain scope | Ethereum only (Phase 1\) | Enables ERC-4337 \+ Kernel \+ EIP-7951 stack. Avoids multi-chain complexity. Kernel WebAuthn validator available on EVM chains. |
| Account model | Kernel smart account (ERC-4337) | Audited by ChainLight and Kalos. 6 million+ accounts. Native WebAuthn/P-256 validator required for Secure Enclave signing via EIP-7951. |
| Approval model | Session key signs in-policy actions. Out-of-policy actions use passkey approval. | One owner (user key), one session-scoped signer. The current app uses fallback, not co-signing. |
| Policy model | Session policy snapshot is stored locally and encoded into Kernel permission data. | App mirrors policy before signing; Kernel enforces the installed permission at execution time. |
| Restore metadata model | On-chain state always recoverable. Local metadata (names, labels) may be lost. Fallback: Account 1, Account 2 etc. | Funds, signer state, policy, installed modules all on-chain. Display names are local-only. Encrypted metadata backup export deferred to Phase 2\. |
| Module versioning on restore | Kernel version and installed modules read from chain at restore. Only compatible features offered. | Social recovery and future modules recoverable only if installed before device loss. Cannot be added retroactively without user key. |
| Session key cost | No standalone enable transaction. | The first in-policy session UserOperation carries enable data if the permission is not installed yet. Explicit revoke submits an on-chain UserOperation. |
| Session key lifespan | Active session record \- deleted on local expiry or revoke. | Compromised old session key becomes useless after local deletion or on-chain `validUntil` expiry. |
| Expiry mechanism | Keychain deletion (local) \+ `validUntil` (on-chain fallback) \+ permission uninstall on revoke. | Multiple independent layers stop silent signing locally and reject expired session UserOperations on-chain. |
| Session key access | Via signing module tool only. Session key in Keychain, read by signing module only. | LLM cannot access Keychain directly. Only signing module process reads the session key. |
| Session key storage | macOS Keychain \- same storage class as bundler key. Silent reads, no Touch ID. | Security relies on on-chain spending policy not key storage. Bounded blast radius. Expires at session end. |
| Spending policy location | On-chain (Kernel contract) | Cannot be bypassed by UI, LLM, or signing module compromise. |
| Rust for crypto core | Yes \- permanent investment | Memory safety, portability. Only platform adapter changes per OS. |
| Self-enclosed default | Yes \- no external services at all | Privacy-first means local only. No hosted fallbacks are offered. |
| Helios for RPC | Yes \- compiled into app binary via Rust SDK | Cryptographic verification of all chain data. Not downloaded at runtime. Trust no RPC, verify everything. |
| Local bundler | Local only \- Custom bundler. One funded sender EOA per account. | Correct ERC-4337 flow: UserOp \-\> simulateValidation() \-\> handleOps() tx \-\> Flashbots. No external bundler option. No automatic public fallback. |
| Helios integration | Rust SDK embedded directly \- not subprocess | Cleaner integration, no IPC overhead, verified data inside same process boundary |
| LLM model | Default small model downloaded on first launch \- no hosted option | No model input or conversation ever leaves the machine |
| Price feeds | On-chain Chainlink via local Helios RPC \- default not opt-in | Free contract read, cryptographically verified, no external API dependency |
| Supply chain \- build time | Cargo.lock pinning \+ cargo-audit in CI \+ cargo-vet for 5 critical crates \+ reproducible builds | Four layered controls protecting compiled binary. Does not protect runtime downloads. |
| Supply chain \- runtime | Only LLM model weights downloaded at runtime. Helios, custom bundler, arti all compiled in. | Model hash pinned in binary, verified before execution, no auto-update to latest, downgrade blocked, failure \= refuse to run. |
| Backup and recovery | No seed phrase. Recovery module is mandatory. Full guardian UX is Phase 2\. | Root key is device-bound hardware \- no seed exists to back up. Device loss is only recoverable via pre-installed recovery module. This is why recovery module setup is mandatory at account creation. |
| Multi-account | One P-256 Enclave key owns all accounts. Separation by CREATE2 contract address with unique salt per account. | No BIP-32 derivation. No mnemonic. Root key compromise affects all accounts simultaneously \- recovery module is the mitigation. |
| Smart contract choice | Kernel | Kernel native WebAuthn/P-256 validator required for Secure Enclave signing. EIP-7951 on mainnet since Fusaka (Dec 2025). |
| Apple key protection model | Model 1 (enclave-resident signing) for root key. EIP-7951 live on mainnet since Fusaka (Dec 2025). | Root P-256 key signs directly in Enclave. Never in RAM. secp256k1 eliminated for root key. Session key uses Model 2 \- acceptable given bounded blast radius. |
| Spending limits | User-configurable ETH cap, ERC-20 token caps, approval scope, rate limit, gas budget, duration, and inactivity timeout. | On-chain enforcement via Kernel permission plus local preflight mirror. Native ETH is allowed only when enabled and under cap; NFTs and unknown contracts remain out of policy. |
| MEV protection | Flashbots Protect via Tor, hash-only hints. Signed handleOps() tx not raw UserOp. | Builder sees UserOp in calldata \- honest limit of pre-inclusion privacy. No automatic public fallback. User prompted after 25 blocks. |
| Full on-chain privacy | Aztec deferred \- not production ready. Designed as future opt-in mode. | Aztec solves the on-chain record problem. Flashbots only solves pre-inclusion. Both needed for full privacy. |
| Session duration | User adjustable: 4h/8h/12h/16h/20h/24h, default 8h | Hard ceiling varies by user preference. Both timers run concurrently, first to fire ends the session. |
| Inactivity timeout | User adjustable: 10min to 4h, default 1h | Only intentional UI or agent actions reset the timer. Background processes do not. |
| UI \- Phase 1 | SwiftUI \+ XPC \- no Tauri | XPC provides OS-enforced process isolation. Tauri IPC is not equivalent. Security over portability. |
| UI \- future platforms | Native per OS \- Linux uses D-Bus \+ seccomp \+ namespaces | Linux security is achievable but requires deliberate configuration. Not a quick port. |
| Linux sandboxing | Deferred to Phase 3 \- out of scope for Phase 1 | Separate engineering problem. D-Bus \+ seccomp \+ namespaces when actively planned. |
| Paymaster | Not offered | Gas sponsorship requires external trust. User pays own gas always. |
| Hosted LLM | Not offered | Provider would see all conversation and tx context. No hosted option exists. |
