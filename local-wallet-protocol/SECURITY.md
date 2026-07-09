# Security Policy

The Local Wallet Protocol crates are a pre-1.0 open-source library surface. They have not yet been independently audited.

## Supported Scope

Security reports are currently in scope for:

- ERC-4337 UserOperation hashing and signing helpers (`wallet-signature`)
- Kernel/WebAuthn account prediction and signature encoding (`wallet-kernel`, `wallet-signature`)
- ABI encoding correctness for the 6-field WebAuthn signature struct
- P-256 low-s normalization behavior
- Modular-permission / session-key signing and enable-digest authorization (`wallet-kernel`: `permission_id`, `encode_enable_data`, `enable_digest` EIP-712; `wallet-signature`: `sign_session_userop_hash`, `wrap_installed_signature`, `wrap_enable_signature`)

Out of scope for now:

- production wallet guarantees
- unsupported forks or modified builds
- hosted infrastructure not controlled by this project
- issues caused by testnet RPC or bundler availability
- the daemon, macOS app, or Swift bridge (report those to the relevant repo)

## Reporting

Please do not open public issues for sensitive vulnerabilities.

Until a dedicated security contact is published, use GitHub private vulnerability reporting if enabled on the repository. If that is not available, open a minimal public issue asking for a private security contact without disclosing exploit details.

## Disclosure

We will acknowledge valid reports when possible, investigate impact, and coordinate a fix before publishing details. Timelines may be slower while the project is in early development.
