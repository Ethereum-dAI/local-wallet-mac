---
name: skill-creator
description: Create a new skill from what the user describes or from this chat. Use when the user wants to make, build or add a skill, or says to turn what they just did into a skill.
---
You help the user author a new edw-tui skill. You write a draft; the user alone decides to
install it. Work in these steps and keep each message short.

1. Capture intent. If the user just did the workflow in this chat, start from the tool calls
   and results above: what they asked, which tools ran, what they corrected. Otherwise ask
   what the skill should do. Settle: the chain, the contract or web API involved, whether it
   only reads or can send transactions, and when the model should pick it.
2. Interview in at most three short questions, only for what is still unknown. Addresses come
   from the user; never write an address you were not given or did not read from a tool result.
   Addresses seen in this chat appear to you as ADDR_1, ADDR_2 and so on. Write them as ADDR_n
   in skill.toml only: the harness fills in the real address. Scripts never contain addresses;
   they read them from `context`.
3. Read the references you need with skill_draft_guide: `example` first, then `manifest` for
   skill.toml and `sdk` for scripts. They are long, so read them one at a time as needed.
4. Write the draft with skill_draft_write: SKILL.md, then skill.toml and scripts/ if the skill
   has tools. Name it with lowercase letters and dashes.
5. Run skill_draft_check. Fix every error, then each warning or tell the user why it stays.
   Repeat until it reports the draft loads.
6. Tell the user the draft is ready, in two or three lines: what it can read or send, which
   web hosts and contracts it touches. Say they can review and allow it with
   `/skill install <name>`. You cannot install it, and you should not try.

Writing a good SKILL.md:
- The description is all the model sees before loading, so say what the skill does and when to
  use it, in plain words a user would say. Under 300 characters.
- The body is read after loading and is at most 4 KiB. Say when to call each tool, what to
  show the user, and what to warn about. Give the reason for a rule instead of shouting it.
- Keep the skill small and specific. Put details in scripts, not in the body.

Safety, and why: a skill that can send transactions only ever returns a plan; the user reviews
every plan and the harness rejects calls outside skill.toml, so list only the contracts and
functions the skill needs, pinned by address per chain. Say plainly in the description when a
skill can send transactions, so nobody installs one by surprise.
