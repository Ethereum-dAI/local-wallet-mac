# Security Policy

Local Wallet is an early-stage demo and developer-tooling repository. It is not a production wallet and has not been independently audited.

## Supported Scope

Security reports are currently in scope for:

- Secure Enclave and Keychain usage in the macOS demo app
- ERC-4337 UserOperation hashing and signing helpers
- Kernel/WebAuthn account prediction and signature encoding
- Self-relayed bundler EOA handling, JSON-RPC authentication, and admin challenge flows in `wallet-node`
- Transport binding behavior in `wallet-node` (loopback HTTP, Unix socket, fd-3/fd-4 spawn contract)
- release packaging scripts and documented developer workflows

Out of scope for now:

- production wallet guarantees
- unsupported forks or modified builds
- hosted infrastructure that is not controlled by this project
- issues caused by testnet RPC or bundler availability

## Reporting

Please do not open public issues for sensitive vulnerabilities.

Until a dedicated security contact is published, use GitHub private vulnerability reporting if enabled on the repository. If that is not available, open a minimal public issue asking for a private security contact without disclosing exploit details.

## Disclosure

We will acknowledge valid reports when possible, investigate impact, and coordinate a fix before publishing details. Timelines may be slower while the project is still in early development.
