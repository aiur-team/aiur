---
ticket_id: MP-E6-C6-T03
feature_id: MP-E6
chunk_id: MP-E6-C6
bucket: 2-platform
title: aiur voice transcripts — list and show voice conversation transcripts from the CLI
status: ready
blocked_by: ["DESIGN-E6 (waived for this ticket: DESIGN-E6 lets C6 proceed; output follows existing CLI table/--json conventions)", MP-E6-C6-T02]
prior_units: []
prior_boundaries: [VOX, CTL]
prior_features: []
prior_findings: []
size_owner: launcher (aiur-engine.sh — one subcommand in cmd_voice)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E6-C6-T03 — `aiur voice transcripts`

## Identity and outcome

- **Bucket / feature / chunk:** 2-platform / MP-E6 / C6.
- **User value:** transcripts are reviewable even headless (`--bg --no-dashboard`) and by the
  operator's coding agent acting as Executor.
- **Deliverable:** `aiur voice transcripts [--target <ticket>|executor] [--limit N] [--json]`
  lists sessions; `aiur voice transcripts <conversation_id> [--json]` prints the full
  transcript (turns, context blocks, tool calls, drafts and outcomes) in order.
  `Aiur.VoiceCLI.transcripts/1` over the C6-T02 API; engine `cmd_voice transcripts`.
- **Non-goals:** deletion (C6-T04); summaries (never).

## Dependencies and blockers

- **Predecessors:** C6-T02. Shares `cmd_voice` with C3-T02; whichever lands first creates it.

## Verified starting point (base `45a290e3`)

CLI dispatch and RPC pattern: `cmd_github_cost` → `run_control_rpc
"Aiur.AgentControlCLI.github_cost([...])"` with whitelisted flag values
(`aiur-engine.sh:3032-3064`), dispatch `case` (`:4142-4150`), usage (`:465`).

## Chosen design

- List columns: id, target, started (local time), duration, end reason, turns, drafts
  (`sent/proposed/discarded/stale`). `--json` prints the index records.
- Show: one line per record: `[hh:mm:ss] you: …`, `assistant: …`, `context(<source>,
  observed <age>)`, `tool <name> → <summary>`, `draft vd_… <status>: …`; `--json` prints the
  raw records.
- Flag values whitelisted in the engine (ticket ids `^[A-Za-z0-9#/_.-]{1,80}$`, conversation
  id regex from C6-T01) before they reach the RPC string (engine precedent comment
  `:3056-3057`).

## Implementation steps

1. Engine subcommand and usage; 2. `Aiur.VoiceCLI.transcripts/1`; 3. `reference/cli.md`
   entry (same PR).

## Non-happy paths

- No transcripts → "No voice conversations recorded." (exit 0).
- Unknown id → exit 1 with "No such conversation".
- Torn tail → printed with a final "(last record incomplete)" line.

## Compatibility and rollout

New command. Rollback: revert.

## Verification

| Test | Expected |
| --- | --- |
| `voice_cli_test.exs` "lists sessions for a target" | fixtures → rows |
| "shows a full transcript in order with drafts and outcomes" | — |
| "rejects an id that is not a conversation id before the RPC" | engine-level test in `src/test/aiur_engine_test.exs` (exists at base) exits 64 |
| "--json round-trips the stored records" | equal |

```bash
env -C src mise exec -- mix test test/aiur/voice_cli_test.exs
make -C src fmt-check lint
```

Run in an implementation worktree with `GITHUB_TOKEN`/`GH_TOKEN` unset and hash-check
`~/.aiur/github-budget/agent-token` before and after.

**Mutation check.** Remove the id whitelist: the injection test fails.

## Completion and handoff

- [ ] CLI + docs in the same PR (AGENTS.md: CLI command → `reference/cli.md`).
- **Dependents:** C9-T01.

## Amendment 2026-10-09 — independent package

Source: [../plan.md](../plan.md) §17. Kevin, 2026-10-09: build the voice assistant as "its own
independent package that can be used separately from [aiur]". The core is the Mix project
`packages/elixir/voice_converse/` (OTP app `:voice_converse`, namespace `VoiceConverse.*`).
It has no `Aiur.*` reference, and aiur is one host behind ports (§17.4). Module moves:
plan §17.9. Core tests run with `env -C packages/elixir/voice_converse mise exec -- mix test`
and do not boot aiur.

- The listing/formatting functions are core code (`VoiceConverse.Transcripts`), exposed as
  `mix voice_converse.transcripts` for standalone hosts. `aiur voice transcripts` is a thin
  wrapper. The aiur CLI reference documents only the wrapper.
