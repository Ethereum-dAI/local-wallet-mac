# Bundler Activation Hierarchy Design

**Date:** 2026-08-13

## Problem

The onboarding activation screen gives its passive `Waiting for funds` status a full glass card while rendering the two actions that resolve the state as low-emphasis links. This reverses the intended hierarchy and repeats the minimum-balance explanation already present above it.

## Approved hierarchy

Keep the full relayer address. Replace the conflicting amount-led heading with `Fund your relayer`, followed by `Send at least 0.005 ETH on Sepolia — 0.01 ETH recommended.` Directly below the address, render the funding paths as real buttons:

- `Copy address` is the filled primary button because every external-funding path needs the destination address.
- `Open Sepolia faucet` is an outlined secondary button and continues to open the faucet without changing the clipboard.

Both buttons remain visible during checking, waiting, and balance-read failures. They should share a row, a consistent height, and enough width to read as the screen's immediate actions rather than tertiary links.

Remove the glass status card. Show one compact status line below the buttons:

- checking: spinner plus `Checking balance`
- waiting: spinner plus `Waiting for deposit — <detected> / 0.005 ETH`
- ready: green check plus `Deposit detected — <detected> ETH`
- failed: warning icon plus `Couldn’t verify balance — Retry`

Use dashes, not centered dots, to separate status phrases and values.

## Interaction and safety

This is a presentation-only change. The existing polling, chain validation, `0.005 ETH` readiness floor, explicit Continue action, cancellation behavior, and no-authentication balance reads remain unchanged. A failed or unavailable read never enables Continue.

The Retry affordance appears only for a failed balance read. Copy and faucet actions remain usable so an RPC problem does not hide the only available funding paths.

## Accessibility

Hide decorative spinners and icons from assistive technologies and expose each status line as one combined announcement. The two funding buttons keep explicit action labels. Keyboard focus order follows the visual order: address, Copy address, Open Sepolia faucet, Retry when present, then Continue.

## Verification

- Run the onboarding activation tests and the full Swift package suite.
- Build the Xcode app with code signing disabled.
- Manually confirm that actions dominate the screen, the status occupies one compact line, dashes are used instead of dots, and the status switches correctly across checking, waiting, failed, and ready states.
