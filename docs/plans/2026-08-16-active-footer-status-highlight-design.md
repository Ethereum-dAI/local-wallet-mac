# Active Footer Status Highlight Design

## Problem

The Thinking and Session key controls use the same neutral pill shell in every state. Thinking changes only its label and symbol. Session key changes only the color of a small symbol. Active states are therefore hard to identify at a glance, and the clickable controls look like read-only status pills.

## Goals

- Make Thinking on and Session key active visually distinct.
- Keep state understandable without relying on color.
- Reuse the existing `StatusPill` component and dashboard palette.
- Preserve the footer's compact visual hierarchy.

## Non-goals

- Redesign the footer or composer.
- Change Thinking or Session key behavior.
- Highlight pending, stored, locked, expired, or unavailable session states.
- Introduce new colors or animation.

## Design

Extend `StatusPill` with an inactive-by-default highlight flag.

Highlighted pills use:

- `ChatPalette.selectedPanel` for the background.
- The supplied semantic tint for a 1 point border.
- `ChatPalette.primaryText` for the label.
- The supplied semantic tint for the symbol.

Neutral pills retain the current panel background, border, secondary label, and supplied symbol tint.

Thinking supplies `ChatPalette.accent` and highlights only when `thinkingEnabled` is true. Session key retains its existing semantic symbol tint and highlights only when `statusTitle` is exactly `Active`. This produces a blue Thinking highlight and a green active Session key highlight while keeping pending and error states visually neutral.

## Accessibility

- Continue rendering explicit state words such as `on`, `off`, and `active`.
- Add an accessibility label and value to the Thinking control.
- Add a help description to the Thinking control, matching the existing Session key and gas controls.
- Keep contrast high by using primary text on the selected panel rather than tint-colored body text.

## Verification

- Add source-level audit coverage proving Thinking binds highlight to `thinkingEnabled`.
- Add source-level audit coverage proving Session key highlights only the exact active state.
- Run the focused dashboard chrome tests.
- Run the full Swift package test suite.

