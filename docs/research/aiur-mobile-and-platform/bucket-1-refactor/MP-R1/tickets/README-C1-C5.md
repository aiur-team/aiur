# MP-R1 tickets, chunks C1–C5

Written by the C1–C5 ticket researcher on 2026-10-06 at base `45a290e3`. The
coordinator merges this with [README-C6-C11.md](README-C6-C11.md). Contract requests to
other owners: [CONTRACT-REQUESTS-C1-C5.md](CONTRACT-REQUESTS-C1-C5.md). The owned
contract [identity-and-capabilities.md](../../../contracts/identity-and-capabilities.md)
was updated directly.

All 26 tickets are `blocked`: every one waits for **DESIGN-R1** (MP-REQ2). The table
says which have further blockers. "Wave" is the order inside delivery wave 1.

## Ticket table

| ID | Title (short) | Blocked by (besides DESIGN-R1) | Sub-wave |
|---|---|---|---|
| C1-T1 | Manifest, schema, ownership check, CI wiring | — | 1a |
| C1-T2 | Elixir walker, R-declared/R-private, allowlist | C1-T1 | 1b |
| C1-T3 | R-down, R-optional, SCC report | C1-T2 | 1c |
| C1-T4 | TS import walker, R-client | C1-T1 | 1b |
| C1-T5 | Ratchet enforcement (stale entries, prune, growth guard) | C1-T2, C1-T3 | 1d |
| C1-T6 | Build-queue seams; delete MP-E1 scan test | C1-T3, **MP-E1-C1-T6** | after MP-E1 |
| C2-T1 | Machine identity store at first boot | (DESIGN-R1 **S3**) | 1a |
| C2-T2 | `Aiur.Identity` facade, `instance_id` | C2-T1 | 1b |
| C3-T1 | Capability registry (table, monitor, boot_id, revision) | C2-T2 | 1c |
| C3-T2 | Core providers | C3-T1 | 1d |
| C3-T3 | `GET /api/v1/capabilities`, error encoder, concepts page | C3-T1 (DESIGN-R1 **S2, S5**) | 1d |
| C3-T4 | `aiur capabilities` verb, aiurdev routing, CLI docs | C3-T1 (DESIGN-R1 **S1**) | 1d |
| C3-T5 | `system.capabilities.changed` | C3-T1 | 1d |
| C3-T6 | `packages/aiur-contracts` + golden test | C3-T3, C1-T4 | 1e |
| C3-T7 | Optional-component providers | C3-T2 | 1e |
| C4-T1 | Registered semantic config checks | C1-T2 | 1c |
| C4-T2 | Turn-sandbox root contributors | C1-T2 | 1c |
| C4-T3 | Accessors out, pure helpers down (6 edges) | C1-T2 | 1c |
| C4-T4 | Env and global-config startup edges | C1-T2 | 1c |
| C4-T5 | Ownership data and O-config/O-env/O-state rules | C1-T1 | 1b |
| C5-T1 | `DecisionLog` → kernel `Aiur.Journal` | C1-T2, **U6 decision-journal** | after U6 |
| C5-T2 | Bounded and process signalling to kernel | C1-T2 | 1c |
| C5-T3 | `Aiur.Signal` alert + refresh port | C1-T2 | 1c |
| C5-T4 | Lifecycle telemetry through the port; Perf/LogFile reassigned | C5-T3 | 1d |
| C5-T5 | Alert emitters outside orchestrator (39 files, 69 sites) | C5-T3 | 1d |
| C5-T6 | Orchestrator alert emitters (22 files, 91 sites) | C5-T3 | 1d |

Design-gate-only after DESIGN-R1 approval: C1-T1, C2-T1 (needs S3), and everything whose
predecessors are inside this table. External blockers: C1-T6 (MP-E1-C1-T6), C5-T1 (U6).

## Dependency order

```text
C1-T1 ─┬─ C1-T2 ─┬─ C1-T3 ─┬─ C1-T5
       │         │         └─ C1-T6 (after MP-E1-C1-T6)
       │         ├─ C4-T1, C4-T2, C4-T3, C4-T4   (same file config.ex: serialize merges)
       │         ├─ C5-T2
       │         ├─ C5-T3 ─┬─ C5-T4
       │         │         ├─ C5-T5
       │         │         └─ C5-T6
       │         └─ C5-T1 (after U6)
       ├─ C1-T4 ─────────────────────── C3-T6
       └─ C4-T5
C2-T1 ── C2-T2 ── C3-T1 ─┬─ C3-T2 ── C3-T7
                         ├─ C3-T3 ── C3-T6
                         ├─ C3-T4
                         └─ C3-T5
```

## What may run concurrently

- C1-T1 and C2-T1 can start together (C2-T1 adds files; if C1-T1 merged first, the
  same PR adds them to `components.json`).
- After C1-T2: C4-T1..T4, C5-T2 and C5-T3 in parallel; C4-T1..T3 all edit
  `src/lib/aiur/config.ex` and must merge one at a time.
- After C3-T1: C3-T2..T5 in parallel. C3-T3 and MP-R1-C6-T1 both edit `router.ex`:
  merge C3-T3 first (README-C6-C11 agrees).
- C5-T5 and C5-T6 touch disjoint directories; both coordinate with MP-R2-C2-T08, which
  edits the same emitter files (second one rebases).
- C2/C3 (identity, capabilities) and C1/C4/C5 (refactor) are independent tracks.

## Test command used in the tickets

Tickets write `$TESTCMD <paths>`. It means, from a **worktree** (never the live
checkout), with an isolated home so `mix test` cannot overwrite
`~/.aiur/github-budget/agent-token` and GitHub tokens are not inherited:

```bash
WT=<worktree>; T="$(mktemp -d)"
env -C "$WT/src" -u GITHUB_TOKEN -u GH_TOKEN HOME="$T" \
  MISE_DATA_DIR="$HOME/.local/share/mise" MISE_CONFIG_DIR="$HOME/.config/mise" \
  mise exec -- mix test <paths>
```

The Python/shell guards (`scripts/check-components.py`, `scripts/test-check-components.sh`)
run from the repository root without that isolation. Every ticket names the production
hunk its new tests must fail without (AGENTS.md); pure renames say "n/a" and name their
regression guards as such.

## Changes to plan and chunks made by Phase C

Recorded in [plan.md §9–§10](../plan.md), [component-map.md](../component-map.md) and
[capability-matrix.md](../capability-matrix.md):

1. **C1:** T6 is now "absorb MP-E1's scan test and the X-1 seams" (RC-11). Self-tests
   no longer have their own ticket: the harness and its `workflow security` step ship in
   **C1-T1**, and each rule ticket ships its fixtures. MP-R1-C10-T4 cites "C1-T6 (checker
   self-tests in workflow security)": that reference should read **C1-T1**.
2. **C2:** `repository` and executor state moved to C3-T2 providers (layering); the
   `session_ref` builder was dropped — MP-E4 owns `SessionRef` (CQ3).
3. **C3:** revision persistence replaced by `boot_id` + in-memory revision; the
   concepts page ships in **C3-T3**, not C3-T7 (docs ship with the change).
   MP-R1-C6-T3 cites "capability concepts page (C3-T7)": it should read **C3-T3**.
   C3-T7 is now the optional-component providers.
4. **C4:** RQ4 decided: no registry-generated `embeds_one`; tickets are organised by the
   24 measured config-layer edges, not by section owner.
5. **C5:** T5 split into T5 (outside orchestrator) and T6 (orchestrator); T2 now moves
   all process signalling (answers Q-1 below).
6. Contract: CR-C6-1 applied (`run_shape.http_listener`, `run_shape.dashboard_pages`).

## Answers to the C6–C11 researcher (README-C6-C11 "Requests to the C1–C5 researcher")

- **Q-1:** accepted. MP-R1-C5-T2 moves the `reap_*`, `process_group_*`,
  `graceful_kill_process_group/1` helpers and `priv/pidfd_reap.py` ownership into
  `Aiur.ProcessTree` (kernel); `RemoteControl` delegates.
- **Q-2:** accepted. `components.schema.json` (C1-T1) allows root `features` and
  `directory_published`.
- **Q-3:** confirmed: the `aiur-contracts` schema ticket is **MP-R1-C3-T6**.
- **Q-4:** confirmed: `github/issues.ex → BuildOrder.Bounded` is fixed by C5-T2;
  `config.ex → BuildOrder.Cadence` by C4-T3 (edge E1).

## Cross-chunk items for the coordinator

- **X-1 (references):** fix the two citations in item 1 and 3 above in C10-T4 and C6-T3.
- **X-2 (overlap):** MP-R1-C5-T3 (`Aiur.Signal.refresh/0`, `subscribe_refresh/0`) and
  MP-R1-C8-T4 deliverable 1 (move `AiurWeb.ObservabilityPubSub` to core
  `Aiur.ObservabilityPubSub` owned by `event-bus`) remove the same core→web edges.
  Recommendation: C5-T3 owns the refresh hint (the prior survey's signal port #11 lists
  "a 'dashboard should refresh' hint"), and C8-T4 drops its item 1. CR-C8-2 to MP-R2 then
  records the topic as internal invalidation owned by `signal`, not `event-bus`. Either
  choice works; the two tickets must not both ship.
- **X-3:** the C6–C11 README's open item G-1/G-2 are not affected by C1–C5.

## New research questions

None blocking. Two implementation-time measurements are required by the tickets:
the 41-component baseline violation counts (C1-T2/T3 PR bodies) and the `npm ci`
cost of the TS walker in the lint job (C1-T4).
