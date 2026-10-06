---
ticket_id: MP-E7-C4-T04
feature_id: MP-E7
chunk_id: MP-E7-C4
bucket: 2-platform
title: "claude-repl: classify pane input as native steer; hold sync until Stop"
status: ready
blocked_by: [DESIGN-E7, MP-E7-C4-T02, MP-E7-C3-T02]
repo: aiur-team/aiur
wave: 4
prior_units: [U4]
prior_boundaries: [CLD (22), RUN (18)]
prior_features: [MP-R7]
prior_findings: [MP-R7 RQ-R7-1, MP-E7 RQ-E7-3]
size_owner: CLAUDE
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E7-C4-T04 — `claude-repl`: native steer and Stop-held sync

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 2 · MP-E7 · C4.
- **User value:** on the persistent REPL, `steer` keeps today's "type it in,
  Claude folds it in after the current tool calls" behaviour, now labelled
  correctly; `sync` stops typing mid-turn and waits for the turn to end.
- **Deliverable:** (1) the REPL turn loops accept the `:steer` wake value
  from MP-E7-C4-T02 as the existing immediate path; (2) `sync` items on
  `claude-repl` are not typed mid-turn and are delivered after the `Stop`
  hook by the existing turn-boundary drain; (3) `mid_turn_inject: :native`
  and `native_queue: true` for `claude-repl`; (4) tests.
- **Non-goals:** `async` on `claude-repl` stays `unsupported` (no pull path:
  the REPL launch has no `--mcp-config`, `claude/repl/command.ex:27-36`).
  Ctrl+C interrupt is unchanged (control, not a mode).

## Dependencies and blockers

- **DESIGN-E7**; **MP-E7-C4-T02** (`:steer` value and `steer_requested`
  flag); **MP-E7-C3-T02** (mode-aware `deliver_now?`).
- **May run concurrently with** C4-T03, C5, C6.

## Verified starting point (at `45a290e3`)

- Today every `claude-repl` message is `:immediate`: accepted policies are
  `[:immediate]` when `immediate_delivery` (`orchestrator/operator_messages/capabilities.ex:76-81`;
  `providers/claude.ex:95-103`), and `:auto` normalises to `:immediate`
  (`delivery_policy.ex:14-16`).
- Mid-turn wake: `{:agent_queue_updated, _, _, true}` →
  `OperatorInject.deliver_immediate_operator_message/2`
  (`claude/repl/hook_turn.ex:146-151`; same in
  `claude/repl/transcript_turn.ex:222-223`); other values are ignored
  (`hook_turn.ex:153-157`).
- Typing path: sanitize, `send-keys -l`, one Enter
  (`claude/repl/operator_inject.ex:29-43,103-108`).
- Hooks wired: `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure`
  (`claude/hook_settings.ex:13-15`), fire-and-forget (`:36-45`).
- Tests: `src/test/aiur/claude/repl/operator_inject_test.exs`,
  `src/test/aiur/claude/repl/hook_turn_test.exs`.

**RQ-E7-3 / RQ-R7-1 — resolved by documentation, confirm by capture.**
Claude Code interactive-mode docs
(https://code.claude.com/docs/en/interactive-mode, accessed 2026-10-06;
local `claude --version` 2.1.291), section "When Claude Code sends what you
queued": "if you queue a message while Claude is running tool calls, Claude
Code passes it to Claude as soon as those tool calls finish, within the same
turn. When the turn ends with messages still queued, they go out without
another key press". That is a non-cancelling tool-boundary injection, i.e.
contract §3 `steer`. Khala's recorded Claude 2.1.283 run shows the same
boundary for its hook path ("Busy steer: PostToolUse supplied context before
the next tool started, without interrupting the running tool";
`experiments/internal-mode/listening-modes/claude/README.md` at Khala
`origin/main` `99e72a43`). Remaining check: one foreground capture on the
pinned dev Claude version (below), after which `(claude-repl, steer)` moves
from `experimental` to `proven`.

## Chosen design

- **Steer:** `:steer` is treated exactly like today's `true` in
  `HookTurn` and `TranscriptTurn` (one added clause each, or a guard
  `when deliver_now in [true, :steer]`). No new typing code.
- **Sync:** C3-T02 makes `deliver_now?/3` return `false` for a `sync` item
  while a turn is active, so the REPL loops ignore it mid-turn
  (`hook_turn.ex:153-154`). At `Stop` the turn returns and the runner's
  existing boundary drain claims it and starts the next turn by typing it
  (the drain is backend-agnostic: `QueueDrain.claim_next_operator_item/2`,
  `agent_runner/checkpoint_delivery.ex:27`). This ticket adds
  `:checkpoint` to the REPL's accepted policies **only for `:listener`
  items** (`capabilities.ex:79`), so a `sync` item is not rejected as
  `:immediate_not_supported` (`delivery_policy.ex:26-28`).
- **Idle:** when no turn is active, `sync` and `steer` both wake (`true`), as
  today (`delivery_policy.ex:177-180`).
- **Primitives:** `claude-repl` `mid_turn_inject: :native` (derived from the
  adapter exporting `steer/3`, which delegates to
  `OperatorInject.send_operator_message/2`), `native_queue: true`,
  `hook_boundaries: [:prompt, :tool, :stop]`.

## Implementation steps

1. `claude/repl_agent.ex` (`Aiur.Claude.ReplAgent`, the registry adapter):
   `@impl true def steer(session, payload, _expected_turn_id), do:
   OperatorInject.send_operator_message(session, payload)`.
2. `hook_turn.ex`, `transcript_turn.ex`: accept `:steer` like `true`.
3. `capabilities.ex:79-81`: listener items on immediate harnesses accept
   `:checkpoint`; legacy behaviour unchanged when routing is `:legacy`.
4. Tests.

## Non-happy paths

- **Fallback `claude-repl → claude`** (`providers/claude.ex:106-110`): the
  running entry becomes headless Claude; effective `steer` drops to
  `emulated_interrupt`/`sync` per contract §4 (recompute is MP-E7-C2-T04).
- **RC promotion** onto `claude-repl`: primitives switch to this row.
- **Pane gone / tmux failure:** existing `on_failure` restores to pending
  (`operator_inject.ex:84-86`).
- **Sync message typed after Stop while the operator types in the pane:**
  unchanged from today's boundary drain risk; no new hazard.

## Compatibility and rollout

Behaviour under `:legacy` routing is byte-identical (MP-R7-C1 suite). Under
`:listener` the REPL default (`sync`) stops mid-turn typing — this is the
E7-D6 behaviour change and only takes effect at MP-E7-C7-T04.

## Verification

- `claude/repl/hook_turn_test.exs`: `"steer wake types into the pane
  mid-turn"`; `"false wake does not type mid-turn"` (guard, passes today).
  **Mutation:** remove the `:steer` clause → first test fails (nothing typed).
- `src/test/aiur/orchestrator/operator_messages/capabilities_test.exs` (exists):
  `"listener item on claude-repl accepts checkpoint"`; `"legacy item on
  claude-repl still accepts only immediate"`. Mutation: revert the
  `capabilities.ex` change → first fails.
- Command: `env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec --
  mix test test/aiur/claude/repl test/aiur/orchestrator`.
- Manual (wrapper-tmux recipe; `claude-repl` routing): (a) `steer`: during a
  multi-tool turn type a message in pane `0.1`; expect Claude to acknowledge
  it before the turn's final answer, with no interrupt. (b) `sync`: same, but
  expect the message to appear only after the turn ends. Capture both with
  `capture-pane -p -S -200`.

## Completion and handoff

- [ ] Tests, mutation checks, both captures in the PR.
- [ ] Parent updates listener-mode §9 `claude-repl steer: experimental →
  proven` (after capture) citing the interactive-mode doc, and
  harness-adapter §3 `claude-repl mid_turn_inject: native`.
- Docs: none here (C7-T05).
