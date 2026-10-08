# U-unit tickets (prior refactor plan U0-U7, U9)

Source plan: [docs/plans/2026-09-29-001-refactor-production-readiness-plan.md](../../../../plans/2026-09-29-001-refactor-production-readiness-plan.md)
(units U0-U9, `requirements-only`). These tickets turn U0, U1, U2, U3, U4, U5, U6,
U7 and U9 into worker-ready tickets with the nine sections of
[brief.md §9](../../brief.md). **U8 (file-size debt) is planned by another agent**
and is not here. MP-R1 does not renumber or absorb U-units
([MP-R1 migration-plan §1, §3](../MP-R1/migration-plan.md)); these tickets only give
the units real IDs so the Build Order can block on them.

All tickets were researched against runtime `origin/main` **`58854d4c8`**
(2026-10-07), not the pack base `45a290e3`. Every file:line in a ticket was
checked at that SHA. Recheck at the implementation SHA when a ticket starts
(MP-R1-C11-T02 runbook; size owner per RC-23).

New dependency edges: [edges.md](edges.md) (58 outbound to MP tickets, 75
inbound/internal; no cycles when merged with `dependency-graph.json`).

## The U0 review gate is now a ticket

RC-19 and MP-R1 migration-plan §2 kept "U0 review before code work" as text
because U0 had no ticket ID. **`U0-T01` is that gate.** It blocks every U1..U7
ticket and the 22 MP-R root tickets (all other MP-R tickets reach it through
their existing predecessors). MP-E1 stays ungated (RC-19). Edit the "There is no
ticket ID for U0" sentences in MP-R1 migration-plan §2 and the MP-R* tickets
READMEs when the edges are applied.

## Ticket table

Complexity: 1 trivial … 5 very large. "Blocks (MP)" lists the MP-R tickets this
ticket must precede (full list with kinds in [edges.md](edges.md)).

| ID | Title | Scope | Predecessors | Blocks (MP) | Cx |
| --- | --- | --- | --- | --- | --- |
| [U0-T01](tickets/U0-T01.md) | U0 review gate | refresh finding dispositions at a pinned SHA, privacy, release identity, sign-off record | U0-T02 | 22 MP-R roots (RC-19), e.g. MP-R1-C1-T01, MP-R2-C1-T01, MP-R7-C1-T01 | 3 |
| [U0-T02](tickets/U0-T02.md) | Refresh oversized-path owner ledger | 373 paths (16 new) with owner, callers, behaviour test, next action | - | MP-R1-C11-T01; U8 tickets | 3 |
| [U0-T03](tickets/U0-T03.md) | Transitional 500-line gate | `scripts/check-file-size.py` in required `workflow security`; CONTRIBUTING | - | (U8 universal gate) | 3 |
| [U1-T01](tickets/U1-T01.md) | Two missing automated P0 witnesses | coalesced-route no-send; credential names inside real bwrap | U0-T01 | - | 2 |
| [U1-T02](tickets/U1-T02.md) | Two-instance stop witness | real-process reap test + live check | U0-T01 | - | 2 |
| [U1-T03](tickets/U1-T03.md) | Packaged Ctrl+C with queued message | foreground acceptance record | U0-T01 | - | 2 |
| [U2-T01](tickets/U2-T01.md) | One ticket-transition owner | `TicketTransition`, ~33 call sites, guard test; answers RQ-U2-TRANSITION | U0-T01, U1-T01..T03, MP-E1-C1-T02/T03/T04 | MP-R1-C7-T07, C7-T08, C9-T06, C9-T07, C9-T09, C9-T13, C5-T06 | 4 |
| [U2-T02](tickets/U2-T02.md) | Guarded terminal-verification wrapper | orch-a-01 + retention bound | U0-T01, MP-E1-C1-T02 | - | 2 |
| [U2-T03](tickets/U2-T03.md) | Rate-limit fallback safety and starvation | orch-b-02, orch-b-08 | U0-T01, U2-T01 | - | 3 |
| [U2-T04](tickets/U2-T04.md) | Waiting reason with owner, cause, since | `WaitingReason.describe/2`, CLI age | U0-T01 | (via U6-T04) MP-R1-C9-T14 | 3 |
| [U2-T05](tickets/U2-T05.md) | Retained workspace lease visible | platform-misc-03 | U0-T01, U2-T04 | - | 3 |
| [U3-T01](tickets/U3-T01.md) | Ordered replay of stalled buffer | events-webhooks-executor-01 | U0-T01 | MP-R2-C2-T01 | 2 |
| [U3-T02](tickets/U3-T02.md) | Claim ownership | events-webhooks-executor-02 | U0-T01 | MP-R1-C9-T11 | 2 |
| [U3-T03](tickets/U3-T03.md) | Wake inbox journal recovery | loose-4-04 | U0-T01, U3-T02 | MP-R1-C9-T11, MP-R2-C2-T10 | 3 |
| [U4-T01](tickets/U4-T01.md) | Settle pause once | agent-runtime-01, -02 | U0-T01, U2-T01 | - (MP-R7-C3 rebases) | 3 |
| [U4-T02](tickets/U4-T02.md) | Condition-driven continuation (measure first) | agents-01..03; conditional on a ≥ 5% no-op share | U0-T01, U2-T01, U3-T01 | - | 3 |
| [U4-T03](tickets/U4-T03.md) | Backend stop and startup-diagnostic safety | agent-backends-cc-04, ANSI redaction, log bound | U0-T01 | MP-R1-C5-T02, MP-R7-C4-T04 | 2 |
| [U5-T01](tickets/U5-T01.md) | Complete paginated readers | github-a-04 | U0-T01 | - | 2 |
| [U5-T02](tickets/U5-T02.md) | One CODEOWNERS trust snapshot (KTD9) | github-a-01, -07 | U0-T01, U5-T01 | MP-R2-C2-T02, MP-R1-C7-T06, MP-R1-C9-T01 | 4 |
| [U5-T03](tickets/U5-T03.md) | Monotonic resource writes | github-b-02 | U0-T01, MP-E1-C1-T01 | (via U5-T04) | 3 |
| [U5-T04](tickets/U5-T04.md) | Typed outcomes, membership witnesses, reply reconcile | KTD11, github-b-03; owns the first-seam startup gate | U0-T01, U5-T03 | MP-R1-C7-T04, C7-T06, C7-T08, C8-T07, C8-T08, C9-T01, MP-R4-C1-T01 | 4 |
| [U6-T01](tickets/U6-T01.md) | Decision journal outcome matrix | loose-1-02, KTD10 | U0-T01 | MP-R1-C5-T01, MP-R1-C8-T02, MP-R2-C3-T01 | 3 |
| [U6-T02](tickets/U6-T02.md) | Projection health and withheld replay | loose-1-03 | U0-T01, U6-T01 | MP-R1-C8-T01 | 3 |
| [U6-T03](tickets/U6-T03.md) | Usage aggregate re-subscribe | telemetry-usage-04 | U0-T01 | - | 2 |
| [U6-T04](tickets/U6-T04.md) | Shared status read model with age | orch-b-01; answers RQ-U6-STATUS-MODEL | U0-T01, U2-T04 | MP-R1-C9-T14, MP-R1-C9-T10 | 4 |
| [U6-T05](tickets/U6-T05.md) | Non-blocking cache loader, unknown cap | web-rest-02, web-occ-07 | U0-T01 | - | 2 |
| [U7-T01](tickets/U7-T01.md) | Census and cut decisions | 7 features; delete one dead script | U0-T01 | MP-R1-C7-T01, MP-R7-C4-T02 | 2 |
| [U7-T02](tickets/U7-T02.md) | Cut Linear (owner-gated) | remove Linear tracker if approved | U7-T01, OWNER, U5-T04 | MP-R1-C7-T02 | 4 |
| [U9-T01](tickets/U9-T01.md) | Net LOC census | census mode in the U0-T03 script | U0-T03 | MP-R1-C11-T03 | 2 |
| [U9-T02](tickets/U9-T02.md) | Integrated release acceptance | foreground multi-agent run; census | all U1..U7, U9-T01, U9-T03, U8 universal gate | MP-R1-C10-T05, MP-R1-C11-T03 | 4 |
| [U9-T03](tickets/U9-T03.md) | npm launcher tests in CI | one `bun test` step | - | - | 1 |

31 tickets. That is more than the expected 18-22 because the 2026-10-07 recheck found
every cited P1 finding still present, and each is a separate fix in a separate
file with its own test. Merging them would make PRs that mix owners (for
example WS and ORC, or web cache and status model).

## Already done (found during the recheck)

- U1: the three P0 repairs are merged (#2827 `57114d675`, #2845 `a03376137`,
  #2846 `12055bff2`). Only witnesses remain (U1-T01..T03). The raw-token leak's
  cause is fixed (`command_runner.ex:10`); the real-bwrap tests likely never run
  in CI (no workflow installs bubblewrap) - recorded in U1-T01.
- U7: cli-38, integrations-20, ui-13 are removed (#2840, #2841); only the
  ledger status needs closing (U7-T01).
- U4: agents-01..03 is partly bounded by #2807 (no-op turn bound, default 3);
  U4-T02 measures before changing anything.
- U2: platform-misc-03 status side is partly fixed (#2810 reason, #2879 reboot exit).
- Nothing else is fixed: all other cited findings are present at `58854d4c8`.

## Changed facts versus the plan

- Oversized tracked text paths: **373**, not 357 (16 new, 0 retired; 88 grew,
  net +4,285 lines). Binary blobs 368 (visual snapshots).
- `website/docs-app/apis/github.md` is 779 lines (plan: 742). Every U5 doc edit
  replaces text in place; the U0-T03 gate forbids growth.
- `aiur-engine.sh` is 4,352 lines; research line numbers in it were stale.
- `CONTRIBUTING.md` line cites moved (:41, :51-52).
- HEAD #3038 made Claude account handoff REPL-only, which blocks cutting
  integrations-09.
- Gemini (#2870) is still an open PR; no Gemini code on main.

## Decisions made without the owner

1. **U0-T01 is a sign-off ticket that depends on U0-T02**; the size gate
   (U0-T03) is part of U0 but does not gate MP-R work.
2. **Size gate baseline = the event's base commit** (PR base SHA, merge-group
   base SHA, push `before`), read from Git blobs, instead of a separately pinned
   baseline commit. Same shrink-only effect, nothing to maintain. Lockfiles and prototypes stay in scope (KTD1).
3. **Only U2-T01 waits for U1** (and U2-T03 through U2-T01). The plan says U2
   depends on U1; U2-T02, U2-T04 and U2-T05 touch no U1 file, so they do not wait.
4. **U4-T03 and U6-T01..T03, T05 do not wait for U2.** They share no file or
   contract with lifecycle; U6-T04 waits for U2-T04 because it renders its fields.
5. **Transition owner name `Aiur.Orchestrator.TicketTransition`**
   (`Aiur.Orchestrator.Lifecycle` is taken), a module in orchestration, not a
   `writer:` option on the `Aiur.Tracker` facade (MP-R1-C7-T01 splits that
   facade; MP-R1-C9-T09 adds `apply_effects/2` to the owner). Replay rule:
   label is authority, no retry in the owner, reconcile before retry; unknown
   outcomes are never recorded as applied. The record is a structured daemon
   log line plus a telemetry event; per-ticket IssueLog rows are deferred
   (IssueLog only accepts events with a `TicketObservation`).
6. **No durable "action receipt" in U3-T03.** Cursor ack = seen;
   `Claims.record_acknowledgement` = owner took it. So the plan's U3 exit
   "attention reports action-pending honestly" is **deferred, not met**, to
   MP-E2 (open item for the owner).
7. **Codex retry state is not persisted** (U6-T04); rows say "since daemon
   start" and point to the forensic startup-failure file.
8. **U4-T02 ships only if no-op continuations are ≥ 5% of turns**, measured
   on the live fleet; otherwise the #2807 bound stays.
9. **U7:** keep REPL/Remote Control (#3038 dependency), keep aiur-build in repo,
   keep `--test`/`--test3`; delete `scripts/aiur-test3-phases` if 0 callers; the
   Linear cut is a separate owner-gated ticket (U7-T02). No physical package
   proposal: KTD11 keeps the first seam in-process and no measured problem asks
   for one. The sidecar TTS delete stays MP-R5-C4-T02 (not duplicated).
10. **No new design tasks.** Rendered changes (ages, "unknown", one new waiting
    reason, alerts) reuse existing renderers and copy style; reviewed in the PR.
11. **U9 does not add a release field to `aiur status`;** acceptance reads the
    build stamp file. The missing `bun test` CI step is its own ungated ticket
    (U9-T03). One acceptance run covers both operating modes (same CLI/TUI).
12. **U1-T01 does not add bubblewrap to CI images;** real-bwrap tests skip
    with a visible reason.
13. **MP-E1-C1 lands first where files overlap** (RC-19): U2-T01 after
    MP-E1-C1-T02/T03/T04, U2-T02 after C1-T02, U5-T03 after C1-T01.
14. **Review merged U5-T05 into U5-T04** (same owner, same doc page) and split
    the CI step out of U9-T02 into U9-T03, so the count stays 31.

## Open items for the owner

- U3 exit "attention reports unknown/action-pending honestly" needs an action
  receipt; deferred to MP-E2 (decision 6). Confirm or reassign.
- U7-T02: cut or keep the Linear tracker after the U7-T01 census.
- U4-T02 threshold (5% no-op continuation share) is an Executor choice.

## Not covered here

- U8 (another agent). Edges into and out of U8 are text notes in [edges.md](edges.md).
- The plan's U4 test "Muse capabilities and unsupported actions remain explicit"
  is covered by MP-R7-C1-T01 (registry-wide harness contract test), not repeated.
- PID-recycle hardening for stop (#2844) stays its own issue.
