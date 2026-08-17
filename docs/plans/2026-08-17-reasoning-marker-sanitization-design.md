# Reasoning Marker Sanitization Design

## Problem

The llama.cpp assistant-turn parser can return a non-empty `reasoning` field that still contains an enclosing marker pair such as `<think>...</think>`. `ReasoningChannelFallback.normalise` currently trusts every non-empty reasoning field, so the dashboard renders those routing markers as visible text.

## Decision

Add one pure, marker-aware sanitizer to `ReasoningChannelFallback`. It will remove only a recognized marker pair that encloses the entire trimmed reasoning value. It will preserve marker-like text embedded in ordinary prose or code examples.

Apply the sanitizer in two places:

1. During assistant-turn normalization, before new reasoning is stored.
2. At the reasoning display boundary, so messages already stored with outer markers render cleanly without a database migration.

Both completed and streaming reasoning should use the same sanitizer rather than duplicating string logic.

## Rejected Alternatives

- A broad regular expression is too destructive because it can alter legitimate examples containing `<think>`.
- A renderer-only fix leaves malformed values in persistence and exports.
- An ingestion-only fix does not repair existing chat history.

## Safety and Failure Behavior

- Strip only exact, recognized outer pairs after trimming whitespace.
- Do not remove unmatched, nested, or embedded markers.
- Preserve content, tool calls, and already-clean reasoning unchanged.
- Treat an empty marker body as absent reasoning.

## Verification

- Add unit coverage for wrapped Qwen reasoning returned through `parsed.reasoning`.
- Cover whitespace, clean reasoning, embedded examples, unmatched markers, and empty blocks.
- Cover display sanitization for persisted reasoning.
- Run the focused reasoning tests and the full Swift package suite.
