---
ticket_id: MP-E3-C4-T01
feature_id: MP-E3
chunk_id: MP-E3-C4
bucket: 2-platform
title: "Executor harness-state machine from hooks, with TTL to unknown and rendered ages"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C1-T02, RQ-E3-5]
prior_units: [U3]
prior_boundaries: [EXE]
prior_features: []
prior_findings: [plan acceptance 5; AGENTS.md computed-age and collapsed-cause rules]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C4-T01 — Executor harness state

## Identity and outcome

- Bucket 2 · MP-E3 · C4 · T01.
- **User value:** the operator sees whether the Executor is working, waiting for
  them, idle, ended, or unknown — never "idle" when aiur simply has not heard.
- **Deliverable:** `Aiur.Executor.HarnessState` (pure reducer + GenServer
  holder) driven by `{:executor_hook, event}`; states `:working |
  :waiting_for_input | :idle | :ended | :unknown`, each with `observed_at`,
  `age_ms`, `freshness`.
- **Non-goals:** wake/roster (existing), blockers (T03), background agents (T02).

## Dependencies and blockers

- DESIGN-E3 (state names and copy, §4 states table).
- MP-E3-C1-T02 (hook events).
- **RQ-E3-5** (Claude `Notification` types meaning "waiting"; Codex equivalent):
  resolved inside this ticket by step 0; listed as a blocker so the mapping is
  not guessed.

## Verified starting point

- Roster states today (`active/idle/stalled/expired/unknown`) come only from
  wake acknowledgements (`src/lib/aiur/executor/roster.ex:1-41`, `build/1` at
  `:50-51`), not from the session itself.
- Hook events available (MP-E3-C1-T02 normalizer): `SessionStart`,
  `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure`, `Notification`
  (Claude, `notification_type`), `SessionEnd`.

## Chosen design

| Event | Transition |
| --- | --- |
| `SessionStart` | `:idle` |
| `UserPromptSubmit`, `PostToolUse` | `:working` |
| `Stop` | `:idle` (unless `stop_hook_active`, then unchanged) |
| `StopFailure` | `:idle` with `last_error` set |
| `Notification` with a type step 0 classifies as waiting | `:waiting_for_input` (`notification_type` kept) |
| `SessionEnd` | `:ended` |
| no hook for > TTL (600 s, binding TTL) | `:unknown` (previous state kept as `last_known`) |
| binding `awaiting_first_hook` | `:unknown`, reason `awaiting_first_hook` |

- `snapshot/0` returns `%{state, last_known, reason, observed_at, age_ms,
  freshness: :fresh | :stale | :unknown}`; `freshness` is `:stale` after 60 s
  without a hook while `:working`, `:unknown` when `observed_at` is nil.
- Ages are always emitted next to the state (AGENTS.md rule 1).

**Step 0 (RQ-E3-5):** with a real Claude Code 2.1.x session attached in a
scratch repo, trigger (a) a permission prompt, (b) an idle wait after a turn,
(c) an `AskUserQuestion`; record each `Notification` payload's
`notification_type` (fields only) into
`src/test/fixtures/executor_hooks/claude-notification-*.json`, and the same for
Codex if it emits one. Map only types observed during a real "needs the
operator" moment to `:waiting_for_input`; others leave the state unchanged.

## Implementation steps

1. Step 0 captures; record results in `MP-E3/plan.md` §10 RQ-E3-5.
2. Pure `reduce(state, event, now)` + `tick(state, now)` for TTL.
3. Holder process subscribed to `"executor_hook"`; tick every 5 s.

## Non-happy paths

- Hooks lost (daemon down) → `:unknown` after TTL; restart begins `:unknown`
  until the next hook (plan §6).
- Out-of-order hooks (two curl calls race) → events carry `observed_at`; an
  older event than the current `observed_at` is ignored.
- Executor waiting on a native question → T03 shows the Command; this state is
  `:waiting_for_input` only if the hook says so.

## Compatibility and rollout

- Projection only. Rollback: revert.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/executor/harness_state_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "no hook within TTL → :unknown with last_known" | `:unknown` | TTL tick (mutation: replace with `:idle` fails — plan acceptance 5) |
| "awaiting_first_hook is :unknown, not :idle" | `:unknown` | binding branch |
| "each event transition" (table) | table | reducer clauses |
| "older event ignored" | state unchanged | ordering guard |
| "snapshot always carries age_ms and freshness; nil observed_at → freshness :unknown" | fields | age fields (mutation: default 0 fails) |
| "fixture Notification types map per step 0" | `:waiting_for_input` only for recorded types | classification |

## Completion and handoff

- [ ] RQ-E3-5 answered with fixtures.
- Dependents: MP-E3-C4-T05, MP-E3-C6-T02, MP-N3.
