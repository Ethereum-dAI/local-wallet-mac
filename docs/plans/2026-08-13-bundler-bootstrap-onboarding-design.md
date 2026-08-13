# Bundler Bootstrap Onboarding Design

## Goal

Prevent a new wallet from reaching the dashboard with a local bundler that cannot relay transactions. Bootstrap the bundler honestly, without an app backend, hosted bundler, paymaster, embedded service credential, or faucet API integration.

## Architectural constraint

The local bundler EOA submits `handleOps` and must pay the outer Ethereum transaction gas. A zero-balance bundler cannot submit the Kernel account operation that would fund that same bundler. EntryPoint reimbursement happens only after the outer transaction has been broadcast, so it cannot solve the initial gas requirement.

The first funding must therefore come from outside the app's local relay path: a Sepolia faucet or another wallet. Once the bundler can relay, the existing Kernel-funded top-up path becomes valid.

## Onboarding placement

Add `Activate transactions` as a dedicated onboarding step immediately after `Create your wallet` and before `Prepare verified reads`:

1. Welcome
2. Connect your chain
3. Configure your AI
4. Create your wallet
5. Activate transactions
6. Prepare verified reads, when consensus verification is enabled

Key creation must finish first because it creates the chain-scoped bundler address. Funding verification uses only that public address and the configured execution RPC; it must not read the bundler secret or trigger authentication.

## Activation screen

The screen is a required gate for an unfunded bundler. It presents:

- title: `Activate transactions`;
- a short explanation that the local relayer needs Sepolia ETH to submit transactions;
- the full bundler address;
- a primary `Copy address` action for funding from any wallet or faucet;
- a separate `Open Sepolia faucet` action with no hidden clipboard side effect;
- a passive status row that checks the balance automatically.

Recommend sending `0.01 Sepolia ETH` to provide a useful buffer. The readiness authority remains the daemon-compatible minimum of `0.005 ETH`; a balance at or above that threshold passes even if it is below the recommendation.

Do not show a Kernel-funded action, chat composer, QR code, manual `I've funded it` confirmation, bundler key details, or raw daemon status on this step.

## State and data flow

The activation state is explicit rather than deriving safety from optional data:

1. `checking`: the app knows the address and is querying its balance. Funding actions remain available, but Continue is disabled.
2. `needsExternalFunding(balance?)`: show the two funding actions and `Waiting for funds`. Poll while the step is visible.
3. `ready(balance)`: show success and enable or automatically perform the normal step transition.
4. `checkFailed(message)`: keep both funding actions available, explain that the app could not verify the balance, and provide Retry. Never interpret an unavailable balance as funded.

Poll the selected execution RPC at a modest interval while this step is visible and perform an immediate check when the app becomes active again. Cancel polling when the user leaves the step. Balance reads must not start a privileged relayer session or request Touch ID.

If an existing or restored bundler is already funded, the check should recognize it and avoid presenting external funding as required.

## Dashboard behavior after onboarding

The dashboard should not show a routine funding control or healthy-status banner. It should surface bundler funding only when actionable:

- while the bundler is still operational but approaching the relay floor, offer an explicit Kernel-funded top-up;
- below the relay floor, remove the impossible Kernel-funded action and show external recovery actions using the same address-copy and faucet-link components;
- while status is unknown, show checking or unavailable state rather than assuming internal funding is possible.

The proactive warning must leave enough balance for the bundler to relay the top-up operation. The daemon remains authoritative about whether submission is allowed.

## Error handling

- Invalid or missing bundler address returns the user to key setup rather than displaying a fake funding target.
- Execution RPC failure does not erase the address or disable external funding actions; it blocks completion until verification succeeds.
- Faucet failure is not an app failure because another wallet remains supported and the app has no faucet API dependency.
- App suspension and focus changes do not reset a confirmed state or request authentication; returning to the step triggers a public balance refresh.
- A reorg or stale RPC response cannot complete onboarding unless the latest observed balance meets the minimum.

## Reuse and scope

Reuse the existing onboarding glass cards, brand buttons, address formatting/copy behavior, chain configuration, Wei parsing, and faucet URL source. Define the activation state and threshold policy once so onboarding, dashboard warnings, intent rejection, and recovery copy do not diverge.

This change does not add a backend, hosted bundler, paymaster, faucet API, automatic faucet claim, direct bundler-to-Kernel sweep, or new relayer signing capability.

## Testing

- State tests for checking, unfunded, exactly-at-threshold, funded, unavailable balance, retry, and cancellation.
- Verify a missing status never enables Continue or the Kernel-funded action.
- Verify both buttons perform only their named action: copy versus open URL.
- Verify polling starts on step entry, refreshes on app activation, and cancels on exit.
- Verify balance checks do not access Keychain, install relayer secrets, or invoke authentication.
- Verify an already-funded existing identity passes without asking for external funding.
- Verify onboarding order and progress count with and without the optional verified-read step.
- Verify dashboard low-balance and below-threshold actions cannot reintroduce the circular funding path.
- Run the full Swift suite, relevant Rust relayer tests, and an unsigned Xcode build.
