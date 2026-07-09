# Security Policy

`local-wallet-daemon` is a v0.1 alpha, app-coupled Ethereum daemon. It is under active development, is not a production wallet, and has not been independently audited.

## Supported Scope

Security reports are currently in scope for:

- ERC-4337 UserOperation policy, allowlist, and gas enforcement in `wallet-bundler`
- Self-relayed bundler EOA handling, JSON-RPC authentication, and admin challenge flows in `wallet-node`
- Transport binding behavior (loopback HTTP incl. `--allow-public`, Unix socket, and the fd-3/fd-4/fd-5 ready/alive/secret spawn contract — fd-5 carries the bundler secp256k1 secret into the daemon)
- Helios-verified read surface in `wallet-chain`
- SQLite persistence and audit/repair flows in `wallet-node-store`
- Release packaging scripts and documented developer workflows

Out of scope for now:

- Production wallet guarantees
- Unsupported forks or modified builds
- Hosted infrastructure not controlled by this project
- Issues caused by testnet RPC or bundler availability
- The macOS app and Swift bridge (those live in [`local-wallet-mac`](https://github.com/Ethereum-dAI/local-wallet-mac))

## Reporting

Please do not open public issues for sensitive vulnerabilities.

Until a dedicated security contact is published, use GitHub private vulnerability reporting if enabled on the repository. If that is not available, open a minimal public issue asking for a private security contact without disclosing exploit details.

## Disclosure

We will acknowledge valid reports when possible, investigate impact, and coordinate a fix before publishing details. Timelines may be slower while the project is still in early development.
