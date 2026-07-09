# Session Key Golden Vectors

This harness emits deterministic Kernel v3.3 permission/session-key vectors from
the ZeroDev SDK. The Rust protocol crates use the emitted JSON as byte-level
fixtures for permission IDs, policy data, enable data, EIP-712 enable digests,
and session-key userOp signatures.

Regenerate fixtures:

```bash
cd tooling/golden-vectors
npm install
npm run emit
cp out/permission.json ../../crates/kernel/testdata/permission/permission.json
cp out/permission.json ../../crates/signature/testdata/permission/permission.json
```

Keep the fixed test keys and addresses stable unless intentionally replacing
all dependent fixtures.
