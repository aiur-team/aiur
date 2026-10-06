---
ticket_id: MP-E7-C5-T04
feature_id: MP-E7
chunk_id: MP-E7-C5
bucket: 2-platform
title: "Agent prompt guidance for aiur_read_messages when async is effective"
status: ready
blocked_by: [DESIGN-E7, MP-E7-C5-T01, MP-E7-C2-T02]
repo: aiur-team/aiur
wave: 4
prior_units: [U4]
prior_boundaries: [RUN (18)]
prior_features: []
prior_findings: []
size_owner: AGENT_TURN (turn prompt)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C5-T04 — Prompt guidance for the pull tool

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C5.
- **User value:** an `async` agent knows that messages may be waiting and
  when to look, without the instruction cluttering every other agent's
  prompt.
- **Deliverable:** a conditional section in the per-turn agent prompt,
  rendered only when the agent's effective mode is `async`, naming
  `aiur_read_messages` and the current `unread_count`.
- **Non-goals:** changing other prompt sections; skill docs (C7-T05).

## Dependencies and blockers

- **DESIGN-E7** (copy of the agent-facing sentence is product text; the
  owner approves it with the mode copy);
  **MP-E7-C5-T01** (tool exists); **MP-E7-C2-T02** (effective mode available
  at prompt build time).
- **May run concurrently with** C5-T02/T03.

## Verified starting point (at `45a290e3`)

- Shared agent instructions live in `src/prompts/shared-agent-instructions.md`
  and name tools by their exact names (e.g. `aiur_set_ticket_state`, `:52-55`).
- The per-turn prompt is built in `agent_runner/turn_prompt.ex` (references
  the shared instructions at `:161`) and `prompt_builder.ex`; tests in
  `src/test/aiur/prompt_builder_test.exs`.

## Chosen design

- Do **not** add the guidance to the static shared file (it would reach every
  agent). Add a small conditional block appended by `turn_prompt.ex` when
  `effective_mode == :async`: two sentences — messages from the operator are
  held, not shown; call `aiur_read_messages` at natural pauses and before
  finishing; plus "N unread" when N > 0.
- The prompt is rebuilt per turn, so a mode change applies at the next turn.

## Implementation steps

1. Read effective mode + unread count in the prompt context (C2-T02,
   C5-T02 data).
2. Conditional block in `turn_prompt.ex` (text from DESIGN-E7).
3. Tests.

## Non-happy paths

- **Mode unknown** (store unreadable): no block (sync default per contract
  §1; never claim messages are held when that is not known).
- **`claude-repl`:** never `async` effective, so never rendered.

## Compatibility and rollout

Prompt-only; inert under `:legacy` routing.

## Verification

- `prompt_builder_test.exs` (or a new `turn_prompt_test.exs`):
  `"async effective mode adds read guidance with unread count"`;
  `"sync mode prompt has no read guidance"`;
  `"unknown mode adds no guidance"` — mutation: treat unknown as async →
  fails. Mutation for the first: delete the block → fails.
- Command: `env -C src HOME=$(mktemp -d) GITHUB_TOKEN= GH_TOKEN= mise exec --
  mix test test/aiur/prompt_builder_test.exs test/aiur/agent_runner`.

## Completion and handoff

- [ ] Approved sentence from DESIGN-E7 cited.
- Docs: C7-T05 adds the `aiur-agent` skill note.
