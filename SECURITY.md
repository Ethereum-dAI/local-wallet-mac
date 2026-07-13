# Security Policy

Local Wallet is an early-stage demo and developer-tooling repository. It is not a production wallet and has not been independently audited.

## Supported Scope

Security reports are currently in scope for:

- Secure Enclave and Keychain usage in the macOS demo app
- ERC-4337 UserOperation hashing and signing helpers
- Kernel/WebAuthn account prediction and signature encoding
- The app side of the daemon-spawn contract: the `posix_spawn` shim and the fd-3/fd-4/fd-5 ready/alive/secret pipes (including the bundler-EOA secret the app writes to fd-5)
- release packaging scripts and documented developer workflows

Out of scope for now:

- production wallet guarantees
- unsupported forks or modified builds
- hosted infrastructure that is not controlled by this project
- issues caused by testnet RPC or bundler availability
- `wallet-node` / `wallet-bundler` / `wallet-chain` daemon internals — self-relayed bundler EOA handling, JSON-RPC authentication, admin challenge flows, and transport binding live in the in-repo local-wallet-daemon workspace and are governed by that workspace's `SECURITY.md`

## Reporting

Please do not open public issues for sensitive vulnerabilities.

Until a dedicated security contact is published, use GitHub private vulnerability reporting if enabled on the repository. If that is not available, open a minimal public issue asking for a private security contact without disclosing exploit details.

## Disclosure

We will acknowledge valid reports when possible, investigate impact, and coordinate a fix before publishing details. Timelines may be slower while the project is still in early development.
