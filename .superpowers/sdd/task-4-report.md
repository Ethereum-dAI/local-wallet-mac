# Task 4 Report: PP host (entropy→mnemonic) + balance/prepareShield mappers

## Status: DONE_WITH_CONCERNS (minor API adjustment, all tests green)

## Files Changed

- `privacy-helper/src/pp.ts` — created (4 exports: `mnemonicFromEntropyHex`, `pickEthBalanceHexWei`, `mapShieldTx`, `createPrivacyPools`)
- `privacy-helper/test/pp.test.ts` — created (3 pure-helper unit tests, verbatim from brief)

## Kohaku API Adjustments vs. Brief

### 1. `PrivacyPoolsV1_0xBow[chainId].entrypoint` shape mismatch

The brief's `createPrivacyPools` does:
```ts
const { entrypoint } = PrivacyPoolsV1_0xBow[opts.chainId];
const pp = new PrivacyPoolsV1Protocol(host, { entrypoint, accountIndex: 0 });
```

But the real installed `PrivacyPoolsV1_0xBow` (from `dist/index.d.ts`) has shape:
```ts
{
  1: { entrypoint: { entrypointAddress: string; deploymentBlock: bigint } };
  11155111: { entrypoint: { entrypointAddress: string; deploymentBlock: bigint } };
}
```

While `IEntrypoint` (the constructor's expected type) is:
```ts
{ address: Address; deploymentBlock: bigint }
```

So `entrypointAddress` in `_0xBow` must be remapped to `address`. Applied fix in `createPrivacyPools`:
```ts
const raw = PrivacyPoolsV1_0xBow[opts.chainId].entrypoint;
const entrypoint = { address: raw.entrypointAddress as `0x${string}`, deploymentBlock: raw.deploymentBlock };
```

### 2. `prepareShield` signature (matched, no change needed)

The brief calls `pp.prepareShield({ asset: ethAsset, amount: BigInt(amountWei) })`. The real type is `prepareShield(assets: PPv1AssetAmount)` where `PPv1AssetAmount = AssetAmount<ERC20AssetId, bigint, undefined>` = `{ asset: ERC20AssetId, amount: bigint }`. This matches the brief exactly — no adjustment.

### 3. `balance()` return shape (matched, no change needed)

`PPv1AssetBalance` = `AssetAmount<ERC20AssetId, bigint, 'pending'>` = `{ asset: { __type: 'erc20', contract: Address }, amount: bigint, tag?: 'pending' }`. This matches the `pickEthBalanceHexWei` interface in the brief (`b.asset.contract` and `b.tag !== "pending"`). No adjustment needed.

### 4. All import names resolved correctly

- `MnemonicKeystore`, `Host`, `Storage` from `@kohaku-eth/plugins` ✓ (via `@kohaku-eth/plugins/dist/host/index.d.ts`)
- `PrivacyPoolsV1Protocol`, `PrivacyPoolsV1_0xBow`, `E_ADDRESS` from `@kohaku-eth/privacy-pools` ✓
- `entropyToMnemonic` from `@scure/bip39` ✓
- `wordlist` from `@scure/bip39/wordlists/english.js` ✓

## TDD RED/GREEN Evidence

### RED (module missing)
```
$ cd privacy-helper && bun test test/pp.test.ts
bun test v1.3.14 (0d9b296a)
test/pp.test.ts:
# Unhandled error between tests
error: Cannot find module '../src/pp.ts' from '.../test/pp.test.ts'
 0 pass
 1 fail
 1 error
Ran 1 test across 1 file. [18.00ms]
```

### GREEN (focused)
```
$ bun test test/pp.test.ts
bun test v1.3.14 (0d9b296a)
 3 pass
 0 fail
Ran 3 tests across 1 file. [244.00ms]
```

### Full suite (no regressions)
```
$ bun test
bun test v1.3.14 (0d9b296a)
 11 pass
 0 fail
Ran 11 tests across 4 files. [177.00ms]
```

## Commit

```
809b2a5 feat(privacy-helper): entropy->mnemonic host + balance(hex)/prepareShield mappers
```

## Self-Review

- Three pure helpers are standalone and import-safe (no side effects, no network/keystore instantiation at module load).
- `createPrivacyPools` is correctly wired: `MnemonicKeystore` takes the mnemonic string, `Host` is assembled with `network.fetch`, `storage`, `keystore`, and `provider`. The `PrivacyPoolsV1Protocol` constructor only requires `entrypoint` (all other params optional).
- The `as any` casts in `balanceHexWei` and `prepareShieldEth` are necessary because the generic `balance`/`prepareShield` return types are narrower than what the pure helper signatures accept — this is acceptable for a bridge adapter; Task 5's Sepolia gate will exercise the live path end-to-end.
- No earlier-task files touched; existing 8 tests still pass.

## Concerns

- The `entrypointAddress` → `address` remap in `createPrivacyPools` is a potential fragility point if the package is upgraded and the `_0xBow` shape changes. Task 5 should verify the mapped address is correct against the on-chain Sepolia deployment.
- `PrivacyPoolsV1Protocol` constructor also accepts `secretManager`, `stateManager`, `relayerClientFactory`, etc. as optional. All left as defaults — Task 5 will confirm whether defaults are sufficient for a Sepolia shield on the 0xBow entrypoint, or if additional wiring (relayer, prover) is needed.

## Follow-up Fix: entrypoint address must be a bigint (post-review)

Coordinator review flagged that `IEntrypoint.address` is `Address = bigint & {}`, and the compiled package treats it as a bigint. Verified against `node_modules/@kohaku-eth/privacy-pools/dist/index.js`:
- line 2505: `` to: `0x${entrypoint.address.toString(16).padStart(40, "0")}` `` — `.toString(16)` on the address.
- line 2255: `processooor: addressToHex(params.entrypoint.address)`.

My original `address: raw.entrypointAddress as \`0x\${string}\`` cast a hex string; at runtime `"0x34A2…".toString(16)` returns the string unchanged, so `padStart(40,"0")` would garble the deposit `to` address. Fixed to build a bigint:
```ts
const raw = PrivacyPoolsV1_0xBow[opts.chainId].entrypoint;
const entrypoint = { address: BigInt(raw.entrypointAddress), deploymentBlock: raw.deploymentBlock };
```
This now matches `IEntrypoint.address: Address` (bigint). Only `createPrivacyPools` changed; the 3 pure-helper tests are unaffected.

```
$ bun test
bun test v1.3.14 (0d9b296a)
 11 pass
 0 fail
Ran 11 tests across 4 files. [355.00ms]
```
