# Dashboard Account, Status, and Product Copy Design

**Date:** 2026-08-13

## Problems

The dashboard currently presents the Kernel account and bundler as two different UI patterns even though both are Ethereum accounts. The Kernel card has a fixed compact summary while the bundler card grows and shrinks with funding state, omits the address from its summary, and exposes a token-list action that is not useful for a gas-paying relayer.

Bundler funding also has two distinct safety states. An externally funded bundler can relay a Kernel-funded top-up, but an empty bundler cannot relay the operation that would fund itself. A generic manual amount form hides that distinction and duplicates the chat interface.

Transaction status is inconsistent because the intent card keeps rendering its submission-time tool response while the transaction card is reconciled from wallet history. The two cards can therefore show `Submitted; receipt pending` and `Transaction included` for the same UserOperation.

The empty chat state spends substantial space on a decorative profile avatar. Product strings also use em dashes inconsistently throughout the app.

## Options considered

### 1. Shared summary card with an agent-driven top-up shortcut

Use one fixed-height account summary component for both accounts. Replace the bundler token-list action with `Top up`. When Kernel funding is viable, the action prefills a natural-language request in the composer and focuses it. The user sends the message, reviews the resulting dedicated bundler top-up intent, and confirms through the existing authentication flow.

When the bundler cannot safely relay a Kernel-funded top-up, the same action exposes only external funding paths. This preserves the no-backend bootstrap while keeping chat as the primary transaction interface.

This is the approved option.

### 2. Expand the bundler card with inline funding controls

This keeps funding visible but prevents the account cards from sharing a stable height, makes the header jump between states, and duplicates amount entry already provided by chat.

### 3. Execute a top-up immediately from the card

This removes an extra step but bypasses the product's intent review pattern and would either request authentication prematurely or fail when the bundler is below its relay floor. It is not acceptable.

## Account-card structure

Extract a shared fixed-height account summary shell and use it for both Kernel and Bundler:

- account icon
- uppercase account title
- shortened, selectable address
- native ETH balance
- optional account-state badge
- injected trailing actions

The resting height is 78 points for both cards. Kernel keeps its token list, Copy, and Explorer actions. Bundler uses Top up, Copy, and Explorer. Remove the bundler token-list popover, token-balance state, token refresh work, and unused parameters rather than merely hiding the icon.

## Bundler top-up interaction

`Top up` is always present when the bundler address is valid.

- If the latest trusted relayer status says a Kernel-funded top-up can be relayed, clicking Top up sets the composer to `Top up the bundler with 0.01 ETH` and focuses it. It does not submit automatically.
- Never overwrite an existing composer draft. If the composer is not empty, keep the draft and focus it instead of replacing the user's text.
- The agent recognizes a dedicated bundler top-up intent. The intent resolves the destination from trusted app state, never from model-supplied address text.
- The product-owned canonical phrase is parsed deterministically when sent, so the button does not depend on model variance. The model tool definition handles equivalent free-text requests through the same intent and execution path.
- The intent card shows the amount and resolved bundler address. The user must explicitly confirm it. Bundler top-ups remain owner-authorized and must not use a session key.
- Confirmation uses the existing bundler-top-up execution path and its exact live relay-cost preflight. It must not degrade into a normal transfer path.
- If the bundler is below the relay floor, an exact preflight previously failed, or balance state is unavailable, Top up opens the external funding recovery UI instead. That UI offers Copy address and Open Sepolia faucet. Unknown state also offers Retry.
- A top-up instruction typed directly into chat follows the same intent and preflight flow. If state changed after the message was prepared, confirmation fails closed before authentication and exposes external recovery actions.

The prefilled amount is an amount to add, not a target balance. This avoids hidden subtraction and race conditions between the displayed balance and confirmation.

## Canonical transaction status

Wallet history becomes the authoritative status overlay for both the intent card and transaction card. The durable tool response remains a fallback and supplies the UserOperation identifier for older conversations.

Use one semantic status model for submitted, pending, included, reverted, and cancelled. Resolve records by case-insensitive UserOperation hash and carry the canonical transaction hash when available. Both cards must render the same terminal outcome and must not reduce cancelled or reverted states to a success Boolean.

## Copy and empty state

- Remove the decorative profile avatar from the empty chat state. Keep the greeting and starter actions vertically centered.
- Change the onboarding line to `Waiting for deposit (0.005 ETH required)`.
- Remove U+2014 em dashes from all runtime product strings, including user-visible errors, placeholders, download states, settings explanations, and Debug Activity messages. Replace each contextually with a period, colon, parentheses, comma, or explicit fallback text.
- Add a source audit test that rejects em dashes on executable app-source lines while ignoring comment-only lines.

## Accessibility

- Give Top up a text label or an unambiguous accessibility label and hint.
- Announce whether external funding is required before its actions.
- Preserve keyboard focus order across Top up, Copy, and Explorer.
- Prefilling the composer moves keyboard focus but never submits or authenticates automatically.
- Status text must include its semantic outcome without relying only on icon color.

## Verification

- Unit-test bundler funding routing across checking, unavailable, externally required, Kernel-top-up candidate, healthy, and forced-external states.
- Verify the Top up shortcut only prefills and focuses the composer.
- Verify the shortcut never overwrites an existing composer draft and that its canonical phrase parses deterministically.
- Test dedicated bundler top-up intent extraction, rendering, confirmation, exact preflight failure, and execution routing.
- Test intent-status reconciliation for mixed-case hash matches and every terminal state.
- Audit that the Bundler card has no token-list state or refresh path and that both account summaries use the shared 78-point shell.
- Audit runtime app source for em dashes.
- Run the full Swift package test suite and an unsigned Xcode build.
