# Wallet Keychain Spike

This spike validates the macOS Keychain entitlement chain. It isolates the risky part:
can a signed helper with `keychain-access-groups` store, read, compare, and delete a
32-byte secret using the intended access group?

**Status:** the spike has been run and the production access-group path has been
proven to require a paid Apple Developer Program membership ($99/yr) plus an
embedded `embedded.provisionprofile`; without those, macOS kills the helper at
launch. The current wallet flow keeps the durable relayer secret in the app's
generic-password Keychain item and passes it to the daemon for RAM-only signing;
production access-group entitlement validation is still tracked as a downstream
production-readiness item (OPEN-8).

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
export CODESIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
bash scripts/run-keychain-spike.sh
```

`CODESIGN_IDENTITY` selects which signing identity from your keychain to use; see `scripts/README.md` for the full list of environment variables the helper script honors.

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
