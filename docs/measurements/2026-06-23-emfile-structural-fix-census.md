# `:emfile` structural fix — process / FD census (2026-06-23)

Companion to `2026-06-22-prewarm-run-findings.md` (the crash) and the
2026-06-22 process-efficiency audit. Covers the structural reductions
landed for #409 on top of the merged prewarm work.

## What landed in this PR

1. **Item 2 — AttachPool fan-out capped to leadoff-only** (the crash
   driver). `background_fill_slot` and the `do_seed` post-boot
   fill-every-slot loop are removed. Each slot now paints exactly its
   one rotational leadoff (`Slot.set_visible`); non-leadoff agents are
   attached nowhere and open on demand via
   `AttachPool.consume → :miss → PaneManager.open_with_placeholder`.
2. **Item 4 — per-identifier DebugLog routing.** Each `SessionWriter`
   subscribes its own sub-topic instead of the global firehose; marks
   route by `entry.identifier || ticket.<id>.` prefix (mirrors
   `EventRow.matches?/2`). No OS-process/FD change — removes
   scheduler/messaging fan-out only.

Deferred to follow-ups: shared `opencode-serve` pool (item 1),
event-driven pane-death + `pipe-pane`-driven capture (items 3/3b),
redundant `ls_remote_ticker` (item 5).

## Attach-layer census (analytical, N agents × M slots)

The attach fan-out is fully determined by the code path, so the
before/after handle counts are exact rather than sampled. The crashing
config was N≈16, M≈16 (`M = min(pre_warmed_sessions, max_concurrent_agents)`,
`slot_policy.ex`).

| Resource (boot burst)            | Before (M×N)        | After (≈M)     |
|----------------------------------|---------------------|----------------|
| `Slot.set_visible` (leadoff)     | M                   | M              |
| `Slot.attach` (background fill)  | M × (N−1)           | **0**          |
| SessionWriter processes          | up to N             | up to N¹       |
| opencode `create_session` rows   | up to M × N         | **≈ M**²       |
| SQLite session rows / DELETEs    | up to M × N         | **≈ M**²       |

¹ One SessionWriter per *distinct attached* identifier. With the fill
gone, a session is created only when an identifier is actually painted
(leadoff) or opened on demand — so the steady-state writer/session
count tracks visible+opened agents (≈ M), not M×N.

² Sessions are created lazily by `SessionWriterRegistry.ensure/2` on the
attach/open path. Capping attaches to the M leadoffs removes the
(M−1)×N sessions that previously existed only to back a marker color —
the issue's "~240 of 256 attaches buy only a marker, not a fast open"
(those agents respawn on open today regardless).

For the crashing config (N=16, M=16): background attaches **240 → 0**;
sessions/SQLite handles **≈256 → ≈16**.

## What still holds FDs after this PR

- **tmux liveness poll** — per visible pane/slot, ~2 forks / 500 ms /
  slot (`slot.ex` `:poll_session`). Bounded by **M slots**, not M×N.
  This is the target of deferred items 3/3b.
- **One `opencode-serve` per slot** (M serves + M ports). Bounded by the
  slot pool, not by agent count — the audit's log-grounded spike showed
  it is *not* the crash driver. Deferred item 1.
- One coding-agent process tree per agent (irreducible) and one
  `beam.smp` for all of aiur.

With the dominant compile storm (prewarm) and the M×N attach handles
(this PR) both removed, the remaining FD holders scale with **M**, not
**M×N** — which is the structural change the acceptance criteria ask for.

## Verification done in this PR

- `Aiur.Regression.AttachFanoutCapTest` — pins the cap behaviorally:
  seeding N=4 agents across M=2 live (mock) slots produces exactly M
  `set_visible` and **0** background `attach` (was M + M×(N−1)).
- `Aiur.Events.DebugLogTest` — pins per-identifier routing parity with
  `EventRow.matches?/2` and that the global topic still receives every
  mark (AgentList / ChatCompletions path preserved).
- Full `test/aiur/{opencode,events,agent_list,regression}` +
  `pane_manager_test` suites green; `mix format` + `mix credo --strict`
  clean.

## Still to capture on hardware (operator)

The acceptance criterion's live high-concurrency run (≈12–16 agents,
survive without `:emfile`, steady-state tmux forks ≤2/sec, writer/session
count ≈ M) needs a real multi-agent box and is an operator measurement.
Recommended capture, mirroring the 2026-06-22 spike methodology:

- `ls /proc/<beam_pid>/fd | wc -l` sampled through boot burst + steady
  state.
- `SessionWriterRegistry` / opencode session-row count at steady state
  (expect ≈ M).
- tmux subprocess fork rate (expect the poll's ~2·M/sec, no M×N term).
