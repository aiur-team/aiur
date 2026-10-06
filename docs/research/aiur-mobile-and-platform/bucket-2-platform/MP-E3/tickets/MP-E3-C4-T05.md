---
ticket_id: MP-E3-C4-T05
feature_id: MP-E3
chunk_id: MP-E3-C4
bucket: 2-platform
title: "Executor.Status.snapshot/0 and its CLI/JSON output (aiur status, executor-session --json)"
status: blocked
blocked_by: [DESIGN-E3, MP-E3-C4-T01, MP-E3-C4-T02, MP-E3-C4-T03, MP-E3-C3-T03]
prior_units: [U3]
prior_boundaries: [EXE, CLI]
prior_features: [MP-N3 (meta-dashboard reads the same snapshot)]
prior_findings: [MP-E3 plan §5 table; AGENTS.md computed-age rule (CLI emits observed_at, age_ms, freshness)]
size_owner: "U8 CLI owner (agent_control_cli.ex)"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E3-C4-T05 — Executor status snapshot

## Identity and outcome

- Bucket 2 · MP-E3 · C4 · T05.
- **User value:** one consistent answer to "what is my Executor doing?" in the
  CLI, the dashboard header (C6-T02) and later the phone (MP-N3).
- **Deliverable:** `Aiur.Executor.Status.snapshot/0` composing binding (T01 of
  C1), harness state (C4-T01), background agents (C4-T02), blockers (C4-T03),
  read capability (C3-T03), and the existing wake/roster data; an `EXECUTOR`
  block in `aiur status`; `aiur executor-session --json` returns the snapshot.
- **Non-goals:** UI (C6).

## Dependencies and blockers

- DESIGN-E3 (field order, compact form). The four projections above.

## Verified starting point

- `aiur status` prints `WAKES CURSOR … PENDING …` (`src/lib/aiur/agent_control_cli.ex:2399-2403`);
  `executor-roster` prints the roster (`:682-700`); `Roster.build/1`
  (`executor/roster.ex:50-51`) returns `%{cursor, pending_count, executors}`.

## Chosen design

```elixir
%{attached: boolean(), binding: map() | nil, harness_state: map(), read_capability: map(),
  background_agents: {:ok, [map()]} | {:unsupported, atom()},
  blockers: map(), wakes: %{cursor, pending_count} | :unavailable, roster: [map()] | :unavailable,
  observed_at: DateTime.t()}
```

- Each part is computed under its own timeout; failure → that key is
  `:unavailable` (never omitted, never defaulted).
- `aiur status` text: one line `EXECUTOR attached=<yes|no> state=<state>
  age=<n>s read=<status> blockers=<n|unavailable>`; with no binding:
  `EXECUTOR not attached (aiur executor-attach --harness claude|codex)`.

## Implementation steps

1. `Status.snapshot/0`; 2. `aiur status` line; 3. `executor-session --json`
   switches to the snapshot (C1-T03 printed the binding only).
4. Docs: `website/docs-app/reference/cli.md` (`status` and `executor-session`
   output changed).

## Non-happy paths

- Any part crashing → `:unavailable` for that key; the command still exits 0.

## Compatibility and rollout

- `aiur status` gains one line; scripts parsing it by prefix are unaffected
  (new prefix). Rollback: revert.

## Verification

```bash
env -C src HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN mise exec -- mix test \
  test/aiur/executor/status_test.exs test/aiur/agent_control_cli_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "part failure → :unavailable key" | key present with `:unavailable` | per-part isolation (mutation: drop key fails) |
| "not attached line" | exact text | branch |
| "json has observed_at and per-part ages" | keys | composition |
| existing `aiur status` tests | green | — regression guard |

## Completion and handoff

- [ ] `reference/cli.md` updated.
- Dependents: MP-E3-C6-T02, MP-N3.
