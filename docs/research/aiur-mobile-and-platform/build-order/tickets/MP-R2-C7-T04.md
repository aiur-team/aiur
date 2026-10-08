---
ticket_id: MP-R2-C7-T04
feature_id: MP-R2
chunk_id: MP-R2-C7
bucket: 1 (Bucket-2-enabling, RC-09)
title: Operator CLI `aiur events tail` and the `aiur status` EVENTS line (only if DESIGN-R2 S2/S3 approve)
status: blocked
blocked_by: [DESIGN-R2 §2 (KQ-R2-2, S2, S3), MP-R2-C7-T01, MP-R2-C6-T03]
prior_units: [U8, U9]
prior_boundaries: [BUS #10, CLI #31]
prior_features: []
prior_findings: []
size_owner: CLI (aiur-engine.sh 4224 and agent_control_cli.ex 3362 in the U8 ledger, both shrink-only); re-check per RC-23
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R2-C7-T04 — `aiur events tail` and the status line

## Identity and outcome

- **Bucket 1, MP-R2, chunk C7. Bucket-2-enabling (RC-09)**; only built if
  Kevin approves DESIGN-R2 **S2** (the command exists) and **S3** (the status
  line and its wording). If S2 is rejected, this ticket is closed and the
  feed stays API-only; if only S3 is rejected, drop part B.
- **User value:** an operator can watch exactly what remote clients receive
  (debugging push/meta-dashboard behaviour) and see feed health in
  `aiur status` without curl.
- **Deliverable A:** `aiur events tail [--after <seq>] [--topic <pattern>]... [--json] [--no-follow]`
  (read-only) in the shared launcher engine, so `aiur` and `aiurdev` both
  get it. **Deliverable B:** one status line
  `EVENTS HEAD <seq> RETAINED <n> OLDEST <age> (sampled <age> ago)` printed
  only when export is enabled.
- **Non-goals:** no write verb; no dashboard UI (DESIGN-R2 §2: an event
  browser belongs to MP-E4).

## Dependencies and blockers

- **DESIGN-R2 §2 S2/S3, KQ-R2-2** — owner decision; status `blocked`.
- C7-T01 (validation rules and the `Aiur.Events.Export.read/3` adapter),
  C6-T03 (`export.meta.json` for HEAD/OLDEST/RETAINED).
- **Size gate (U0, shrink-only for grandfathered paths):** both CLI files
  are oversized. The PR must not grow either; see "Chosen design".

## Verified starting point (45a290e3)

| Fact | Evidence |
| --- | --- |
| Engine main dispatch `case` (status, agents, executor-listen, executor-wait, …) | `packaging/npm/aiur-cli/libexec/aiur-engine.sh:4106-4172` |
| Streaming verb pattern: parse `--topic`, base64-encode, `run_control_stream "Aiur.AgentControlCLI.executor_listen(...)"` | `aiur-engine.sh:3152-3167` |
| `run_control_stream` (no 10 s RPC timeout; liveness probe; down → `print_control_down_message`) | `aiur-engine.sh:2553-2572`; not-running wording `:2281-2283` |
| Usage text lists every verb | `aiur-engine.sh:460-475` (executor-listen at `:469`) |
| Elixir entry for streams: `AgentControlCLI.executor_listen/1` delegates to `ExecutorEvents.listen/1` | `src/lib/aiur/agent_control_cli.ex:420-421` |
| Status report header lines printed first (`LISTENER …`, `WAKES CURSOR … PENDING …`, CODEOWNERS trust) | `agent_control_cli.ex:189-192,2397-2404` |
| Status tests assert `WAKES CURSOR` lines | `src/test/aiur/agent_control_cli_test.exs:982,1011` |
| Launcher test enumerates non-launch verbs (must include a new verb so it never provisions tmux/opencode) | `packaging/npm/aiur-cli/test/launcher.test.mjs:250-258` |
| CLI reference: verb table and `aiur status` row | `website/docs-app/reference/cli.md:30,90,195-243` |
| Size ledger: `aiur-engine.sh` 4224 (CLI), `agent_control_cli.ex` 3362 (CLI) | `docs/research/refactor-2026-09-26/synthesis/u8-release-007/assignments.csv` |
| Shrink-only rule for grandfathered paths | `docs/research/refactor-2026-09-26/synthesis/u0-500-line-migration-gate-2026-09-29.md:49,61` |

## Chosen design

### A. `aiur events tail`

- Engine: one dispatch arm `events) shift; cmd_events "$@" ;;` and
  `cmd_events` accepting only the `tail` subcommand. Flags: `--after <seq>`
  (non-negative integer), `--topic <pattern>` (repeatable), `--json`,
  `--no-follow`. Unknown flag → exit 64 with a usage line (engine
  convention, `:3159`). Topics are base64-encoded into the RPC expression
  exactly like `cmd_executor_listen` (no shell-injection path).
- Elixir: new module `Aiur.EventsCLI` (PROPOSED,
  `src/lib/aiur/events_cli.ex`) with `tail/1`, called via
  `run_control_stream "Aiur.EventsCLI.tail(...)"`. It runs **inside the
  daemon node** and reads through `Aiur.Events.Export.read/4` (C6-T02 signature) +
  the `events:export` notification (C7-T02), so it works with
  `--no-dashboard` and needs no HTTP credentials.
- Output: one line per record. Default text:
  `<seq> <topic> <class> <k=v refs…>` (`gap`/`reset` printed as
  `<seq> GAP scope=<s>` / `RESET oldest=<n> head=<n>`); `--json` prints the
  external envelope JSON line unchanged. Default `--after` is `head_seq`
  (live only), matching the API.
- States (DESIGN-R2 §3, wording copied):
  - disabled → stderr `event export is disabled (events.export.enabled: false)`, exit 1;
  - empty + `--no-follow` → nothing, exit 0; empty + follow → waits;
  - daemon offline → the engine's existing not-running message, exit 1;
  - journal corrupt → stderr `events_unavailable`, exit 1;
  - stale cursor → one `RESET` line, then live.
- Read-only: there is no flag that writes; Ctrl-C ends the stream.

### B. Status line

`Aiur.EventsCLI.status_line/0` returns `nil` when disabled, else
`"EVENTS HEAD #{head} RETAINED #{n} OLDEST #{age} (sampled #{s}s ago)"`;
unreadable → `"EVENTS unavailable (export journal could not be read)"`
(mirrors the WAKES unavailable line). `OLDEST` is the age of the oldest
retained record's `observed_at`; the `sampled` age renders the meta read's
age (AGENTS.md "If a surface computes an age, it renders the age").

### Size-gate handling (decided)

- `agent_control_cli.ex`: move `print_executor_listener_status/0` and
  `print_executor_wake_status/0` (`:2378-2404`, 27 lines) into a new
  `Aiur.StatusHeaderLines` module together with the EVENTS line, and replace
  the three calls at `:190-192` with one `StatusHeaderLines.print()` →
  file shrinks; output order unchanged (LISTENER, WAKES, EVENTS, CODEOWNERS
  — EVENTS goes after WAKES; CODEOWNERS stays where it is).
- `aiur-engine.sh`: the new arm is one line; `cmd_events` needs ≈15. Offset
  by extracting the `--topic` parse + base64 encode that
  `cmd_executor_listen` (`:3152-3166`) does into a helper
  `encode_topic_flags` used by both verbs, and collapsing the
  `executor-listen)` arm to one line. If the measured net is still > 0 when
  implemented, this ticket waits for the U8 CLI owner's engine split
  (record that in the PR) — it must not take a size-gate exception.

## Implementation steps

1. Confirm DESIGN-R2 S2/S3 answers; apply any wording change Kevin made.
2. `Aiur.EventsCLI` (`tail/1`, `status_line/0`).
3. `Aiur.StatusHeaderLines` extraction + EVENTS line.
4. Engine arm, `cmd_events`, `encode_topic_flags`, usage line after `:469`.
5. Add `"events"` to `nonLaunchCommands` in `launcher.test.mjs:250-258`.
6. Docs (below).

## Non-happy paths

- Daemon down, disabled, corrupt, stale cursor: as listed above.
- Many records: the stream pages by 500 internally; output is flushed per
  line so piping to `jq` works.
- Multiple concurrent `tail`s: each has its own cursor; no server state.
- No secrets or free text: records are allowlisted envelopes (C5-T02). In
  particular a `human-needed` record carries no `attrs.short_label` (agent-
  authored text; security m3, C5-T03): `short_label` travels only in the
  sealed push (MP-N4), and `tail` prints only refs and enum attrs.

## Compatibility and rollout

New verb only; `aiur status` gains a line only when export is enabled
(byte-identical output when disabled — plan AC6). Rollback: revert.

## Verification

1. `src/test/aiur/events_cli_test.exs` (PROPOSED)
   - `"tail prints records after the cursor and exits with --no-follow"` —
     fixture seq 1..5, `tail(after: 2, follow: false)` → lines for 3, 4, 5.
   - `"tail on a disabled export prints the disabled message and exits 1"` —
     assert exact DESIGN-R2 wording.
   - `"stale cursor prints one RESET line"`.
   - `"--json prints the envelope unchanged"` — decode and compare to the fixture record.
   - `"status_line is nil when disabled"`; `"status_line renders HEAD, RETAINED, OLDEST and sampled age"`.
2. `agent_control_cli_test.exs`: existing `WAKES CURSOR` assertions (`:982,1011`)
   unchanged (guards the extraction); new
   `"status prints EVENTS after WAKES only when export is enabled"`.
   **Fails if the line prints when disabled** (mutation: drop the `nil` branch).
3. `launcher.test.mjs`: `non-launch events never probes or provisions interactive tools` (generated by step 5).
4. Size: `wc -l` of both CLI files ≤ base values (paste in PR).

```text
env -C <worktree>/src HOME=<tmp> GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/events_cli_test.exs test/aiur/agent_control_cli_test.exs
env -C <worktree>/packaging/npm/aiur-cli bun test test/launcher.test.mjs   # package.json:16 "test": "bun test"
```

Mutation check: remove the disabled-check in `status_line/0` → test 2
fails; remove `"events"` handling from the engine → launcher test fails.

Manual (AGENTS.md "Manual testing"): `scripts/aiurdev --test` with export
enabled; in a second shell `scripts/aiurdev events tail` shows the boot
`GAP` and live records while an agent works; `scripts/aiurdev status`
shows the EVENTS line after WAKES; with export disabled the command prints
the disabled message and `status` has no EVENTS line. Capture both outputs
in the PR.

## Completion and handoff

- [ ] Built only after S2/S3 approval; wording matches the approval.
- [ ] Tests added and mutation-checked; CLI files did not grow.
- [ ] Docs (AGENTS.md "Docs ship with the change": new CLI command + changed
      documented output): `website/docs-app/reference/cli.md` — add
      `events tail` to the verb table (`:30`) and the "Decisions, Executor
      events, and findings" section (near `:242`), and add the EVENTS line to
      the `aiur status` row (`:90`). Usage text in `aiur-engine.sh`.
- Dependents: none in MP-R2; MP-N4/N5 implementers use it for debugging.
