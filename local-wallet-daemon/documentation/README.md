# Local Wallet Documentation

This directory contains the human-facing architectural documentation for Local Wallet — the "why" behind the code, intended for developers reading this repo as a reference, contributors, security reviewers, and anyone forking it for their own opinionated wallet.

For per-crate API documentation and stability claims, see each crate's README under `crates/`.

## Contents

- [`architecture.md`](architecture.md) — design decisions and their rationales
- [`forking-for-your-wallet.md`](forking-for-your-wallet.md) — worked example: retargeting Local Wallet for a different account profile
- [`whats-not-here.md`](whats-not-here.md) — explicit non-goals and deferred features

## Audience

These docs assume familiarity with Ethereum, ERC-4337, and macOS development at a working level. They do NOT re-explain Solidity, alloy, Helios, or the Secure Enclave — they explain *why this codebase made the choices it made*.

If you're trying to *use* Local Wallet's daemon as a service, start with `crates/wallet-node-api/README.md` instead — that's the public surface and stability policy.
