# Wallet Keychain Spike

This spike validates the macOS Keychain entitlement chain before Phase 4 integration.
It isolates the risky part: can a signed helper with `keychain-access-groups` store,
read, compare, and delete a 32-byte secret using the intended access group?

The binary writes a random 32-byte generic password item under service
`com.localwallet.spike` and account `keychain-spike-test-1`, reads it back, verifies
the bytes match, and deletes it.

Prerequisites:

- macOS
- Xcode command-line tools
- A paid Apple Developer Program team with an Apple Development signing identity when validating `keychain-access-groups`

Run:

```bash
export DEVELOPER_TEAM_ID=YOURTEAMID
bash scripts/run-keychain-spike.sh
```

Find your signing identity with:

```bash
security find-identity -v -p codesigning
```

Common failure modes:

- `errSecMissingEntitlement (-34018)`: binary not codesigned with `keychain-access-groups` entitlement.
- launch killed with signal 9 / exit 137: macOS rejected the entitlement/provisioning chain before the helper could run. This is expected with a free Apple ID when testing access groups.
- `errSecNoAccessForItem (-25243)`: access group mismatch, usually a wrong team prefix.
- `errSecAuthFailed (-25293)`: keychain locked or biometric/user authentication required.
- `errSecItemNotFound (-25300)`: item was never stored, so the store step likely failed silently.

Cleanup after a failed run:

```bash
security delete-generic-password -s com.localwallet.spike
```

For next-level validation, submit the resulting app bundle with
`xcrun notarytool submit`. This spike does not notarize the bundle.
