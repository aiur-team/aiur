# MP-R1 tickets — chunks C6 to C11

Written on 2026-10-06 against base `45a290e3`. This section covers 43 tickets. Tickets for
C1–C5 are written by another researcher, who also writes the main `README.md`. Contract
requests from these chunks are in
[CONTRACT-REQUESTS-C6-C11.md](CONTRACT-REQUESTS-C6-C11.md).

## Status rule

All 43 tickets are `blocked`. Each one waits on **DESIGN-R1** (MP-REQ2), plus the
predecessors listed below. 11 C9 tickets are marked "research complete; only DESIGN-R1
and named predecessors remain" in their frontmatter. Every other ticket also has a
named open item: a research question, a prior U-unit, or an owner decision.

- MP-R1 is wave 1 (value-and-sequencing.md). "Lane" below means a dependency chain
  inside wave 1. It is not a delivery wave.
- The `Blocked by` column leaves out DESIGN-R1, because every ticket has it.

**U0 gate (X-58, RC-19).** Every MP-R1 ticket also waits for U0 review of the prior plan
(`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`), because RC-19 keeps
that gate for refactor work. This includes the Bucket-2-enabling chunks C2/C3 (RC-12).
U0 has no ticket ID, so the gate is stated here and in [plan.md](../plan.md), not in
`blocked_by`; the MP-R1-C11-T02 recheck does not replace it.

## Ticket table

| ID | Title | Blocked by | Lane |
|---|---|---|---|
| C6-T01 | Split the router into component-owned route modules, kept in a fixed order | C1-T01, C3-T03 | web |
| C6-T02 | Components register their own endpoint sockets | C1-T01 | web |
| C6-T03 | Internal run shape: HTTP listener and JSON API on, dashboard pages off | C6-T01, C3-T01 | web |
| C6-T04 | Operator flag for that run shape | DESIGN-R1 S4, C6-T03 | web |
| C7-T01 | Tracker split into IssueTracker and CodeHost ports | C1-T01, C1-T03, MP-E1-C1 | tracker |
| C7-T02 | Register tracker adapters instead of naming them in a `case` | C7-T01, C4-T01 | tracker |
| C7-T03 | Agent-sandbox boundary (non-GitHub edges) | C1-T01, C1-T03, C5-T02, C5-T03 | sandbox |
| C7-T04 | GitHub parts of the agent environment behind a registered contributor | C7-T03, U5 | sandbox |
| C7-T05 | Workspace boundary | C7-T02, C7-T03, C7-T04, C5-T02, C5-T03 | sandbox |
| C7-T06 | GitHub family as one logical component (KTD11, no new package) | C1-T01/T03/T05, C5-T03, U5, MP-E1-C1 | github |
| C7-T07 | Dispatcher candidate fetch and revalidation go through the tracker facade | C7-T01, C7-T02, C7-T06, U2, MP-E1-C1 | github |
| C7-T08 | CI-readiness gate leaves Dispatcher; its last direct GitHub calls go | C7-T06, C7-T07, U2, U5, MP-E1-C1 | github |
| C8-T01 | `Aiur.Commands` facade and migration of outside callers | C1-T01/T03/T05 | commands |
| C8-T02 | Answer delivery goes through an orchestration-provided delivery-target port | C8-T01, U6 journal matrix | commands |
| C8-T03 | Projections: Units row model and policy leave the web namespace | C1-T01/T03/T05 | projections |
| C8-T04 | Projections: remaining edges and manifest reassignments | C8-T03, C5-T03 (RC-24), #3009 fixed or deferred | projections |
| C8-T05 | Display sanitizer moves from build-orders to kernel | C1-T01/T03/T05 | conv/BO |
| C8-T06 | `Aiur.Conversation.History` read facade | C8-T05, MP-R6-C1, C1-T03 | conv/BO |
| C8-T07 | Remove GitHub's references into build-order modules | C1-T03/T05, U5 | conv/BO |
| C8-T08 | Build-orders facades, component-owned child specs, new `ticket-context` component | C8-T05, C8-T07, C5-T02, U2 graph contract | conv/BO |
| C8-T09 | Build queue moves from its wave-0 seam to its final shape | MP-E1 C1–C7, C1-T03/T05, C5-T03, C3-T01, C8-T08, MP-E1 owner review | conv/BO |
| C9-T01 | GitHub listener supervisor; firehose cursor fields leave `Orchestrator.State` | C1-T01/T02, C7-T06, MP-R2-C2-T08, U5, MP-E1-C1 | listeners |
| C9-T02 | Comment poll reads plain inputs and a cursor struct, not `State` | C9-T01, MP-R2-C2-T08, MP-E1-C1 | listeners |
| C9-T03 | Comments listener process owns the comment-poll cursor | C9-T01, C9-T02, MP-E1-C1 | listeners |
| C9-T04 | Command-scan listener | C9-T02, C9-T03, MP-E1-C1 | listeners |
| C9-T05 | `PRHealthScanner` moves into `pr-lifecycle` | C1-T01/T02 | pr-lifecycle |
| C9-T06 | `ReworkRequeue` moves into `pr-lifecycle` | **RQ-U2-TRANSITION**, U2, C9-T05, C1-T02 | pr-lifecycle |
| C9-T07 | `Orchestrator.State` field-owner table and a write-site ratchet test | C1-T01, MP-E1-C1 | core |
| C9-T08 | Remove facade back-calls that are not transitions | C9-T07, C1-T02, MP-E1-C1 | core |
| C9-T09 | Transition back-calls return effects to U2's lifecycle owner | **RQ-U2-TRANSITION**, U2, C9-T07, C9-T08, MP-E1-C1 | core |
| C9-T10 | Control-CLI kernel: output protocol and reason renderer | C1-T01/T02 | cli |
| C9-T11 | Executor verbs move to executor-attention | C9-T10, U3 | cli |
| C9-T12 | Control verbs move to orchestration's control CLI | C9-T10, C9-T11 | cli |
| C9-T13 | `--todo` verb moves; MP-E1's `queue` verb stays on its own module | C9-T10, C9-T12 | cli |
| C9-T14 | Read verbs move after U6's shared status model | U6, **RQ-U6-STATUS-MODEL**, C9-T10, C9-T13 | cli |
| C10-T01 | Public manifest fields and the generated planned-features list | C1-T01; DESIGN-R1 §3 Q4/Q5 for `public` flags | directory |
| C10-T02 | Build-time VitePress data loader and an unlisted placeholder page | C10-T01 | directory |
| C10-T03 | Render the page to the approved DESIGN-R1 design | DESIGN-R1 §3 (layout, Q1, Q3, Q4, Q6–Q8, copy), C10-T02 | directory |
| C10-T04 | Docs-sync rules that also run on docs-only PRs; docs rebuild when the manifest changes | C1-T01, C10-T01 | directory |
| C10-T05 | Publish: sidebar entry, AGENTS.md row, go-live | DESIGN-R1 §3 final approval, C10-T03, C10-T04, all of C9, C11-T03 | directory |
| C11-T01 | Plan-refresh tool: path map, stale citations and size owners (research branch) | C1-T01 | refresh |
| C11-T02 | Plan refresh after each move, and size-owner lookup at ticket start (RC-23 runbook) | C11-T01 | refresh |
| C11-T03 | Final plan refresh before wave 2 and before the page goes live | C11-T02, all of C9 | refresh |

## Dependency order inside C6–C11

```text
web:          C6-T01 ─┬─> C6-T03 ─> C6-T04          C6-T02 (independent)
tracker:      C7-T01 ─> C7-T02 ─┐
sandbox:      C7-T03 ─> C7-T04 ─┴> C7-T05           (MP-R7 starts after C7-T03/T04)
github:       C7-T06 ─> C7-T07 ─> C7-T08            (C7-T07 also needs C7-T01/T02)
commands:     C8-T01 ─> C8-T02
projections:  C8-T03 ─> C8-T04
conv/BO:      C8-T05 ─> C8-T06;  C8-T07 ─> C8-T08 ─> C8-T09   (C8-T08 also needs C8-T05)
listeners:    C9-T01 ─> C9-T02 ─> C9-T03 ─> C9-T04   (C9-T01 needs C7-T06)
pr-lifecycle: C9-T05 ─> C9-T06
core:         C9-T07 ─> C9-T08 ─> C9-T09
cli:          C9-T10 ─> C9-T11 ─> C9-T12 ─> C9-T13 ─> C9-T14
directory:    C10-T01 ─> C10-T02 ─> C10-T03 ─┐
              C10-T01 ─> C10-T04 ───────────┴> C10-T05 (after all of C9 and C11-T03)
refresh:      C11-T01 ─> C11-T02 (recurring) ─> C11-T03 (after all of C9)
```

## What can run at the same time

- **First tickets that can start** once DESIGN-R1 and C1-T01 are done: C6-T02, C7-T01,
  C7-T03 (also needs C5-T02/T03), C8-T01, C8-T03, C8-T05, C9-T05, C9-T07, C9-T10, C10-T01 and
  C11-T01. These lanes do not touch the same files.
- **Lanes that share files and must merge in series:**
  - C6-T01 and C3-T03 both edit `router.ex`. Merge C3-T03 first.
  - C7-T03, C7-T04 and C7-T05 share sandbox files.
  - C9-T01 to C9-T04 must wait behind MP-R2-C2-T08, which edits the same files.
  - The C9-T10 to C9-T14 merges all touch `agent_control_cli.ex`. The work can overlap.
  - C7-T07/T08 and C9-T07/T08/T09 all touch `dispatcher.ex` and `state.ex`. Run C7-T07/T08
    first, then C9-T07.
- **C10-T02, C10-T03 and C10-T04** can be developed against fixtures while the moves
  continue. Only C10-T05 waits for the end of the refactor (D20).
- Running in parallel during research does not mean the tickets can be implemented in
  parallel. Each ticket names its predecessors.

## Binding decisions applied

- **RC-19 / RC-20:** every ticket that touches `issue_sync.ex`, `dispatch_policy.ex`,
  `github/labels.ex` or `github/issues.ex` is listed with `MP-E1-C1` in its blockers.
  That covers C7-T01, C7-T06, C7-T07, C7-T08, C8-T09 and C9-T01 to C9-T04, C9-T07 to C9-T09.
  Each one rebases over E1-C1 and has a test that the hooks survive. The queue is a
  sanctioned caller of the single label-writer seam. C8-T09, C9-T07 and C9-T09 have
  guard tests for this.
- **RC-23:** every ticket says that its `size_owner` is looked up again at ticket start,
  in the current U8 ledger. The procedure is MP-R1-C11-T02 Procedure B, and the
  MP-R1-C11-T01 tool automates the lookup.
- **RC-11:** C8-T09 keeps the rank-and-hold lookup in `DispatchPolicy` and the
  claim-check interface.
- **RC-06 / RC-07:** C8-T06 builds on MP-R6-C1's neutral anchor module and does not
  extract it again.
- **RC-21:** C7-T06 cites "U5 first".
- **KTD11:** C7-T06 creates a logical manifest component only, with no package, process
  or new facade module.

## How these tickets map to the plan.md §9 ticket lists

The plan's provisional ticket lists were refined with evidence. When the plan's ID and
the ticket ID differ, use the ticket ID.

| Plan §9 (old) | Tickets |
|---|---|
| C6 T01–T04 | C6-T01 to T04 (same meaning; T04 is the operator flag, blocked on S4) |
| C7 T01–T06 | T01 split, T02 registration, T03 sandbox, T04 sandbox GitHub contributor, T05 workspace, T06 GitHub component; the old T06 "Dispatcher" became T07 and T08 |
| C8 T01–T05 | T01/T02 Commands, T03/T04 projections, T05/T06 conversations, T07/T08 build-orders, T09 build queue |
| C9 T01 listeners | C9-T01 to T04 |
| C9 T02 PRHealthScanner / ReworkRequeue | C9-T05, C9-T06 |
| C9 T03 state-field owners | C9-T07 (and C9-T08) |
| C9 T04 effects | C9-T09 |
| C9 T05 CLI split | C9-T10 to T14 |
| C10 T01–T04 | C10-T01 to T05 (T02 was split into the loader, T02, and the approved design, T03) |
| C11 T01–T03 | C11-T01 to T03 (same) |

## Requests to the C1–C5 researcher (cross-chunk, inside MP-R1)

- **Q-1 (from C7-T05):** MP-R1-C5-T02 must also move the `reap_*` and
  `process_group_alive?` helpers (`src/lib/aiur/claude/remote_control.ex:266-354`).
  Moving only the graceful-kill helpers is not enough, because C7-T05 depends on all of
  them.
- **Q-2 (from C10-T01, C10-T04):** `components.schema.json` must accept the top-level
  `features` array and the `directory_published` flag that C10-T01 and C10-T04 add. The
  simplest form: the root object allows those two keys.
- **Q-3 (from C10-T04):** the ticket ID of the `packages/aiur-contracts` capability
  schema is plan C3-T06. If the final ID differs, C10-T01 and C10-T04 cite the plan ID and
  must be updated.
- **Q-4 (from C8-T08):** `src/lib/aiur/github/issues.ex` references
  `BuildOrder.Bounded`; C5-T02 owns moving it. `config.ex` references
  `BuildOrder.Cadence`; C4 owns that.

## Open items with no owner yet (for the coordinator)

- **G-1:** the `GitHub.Issues → Orchestrator.DispatchPolicy` edge
  (`src/lib/aiur/github/issues.ex:23,952,1132`) stays in the allowlist. C7-T06 proposes
  that C9-T09 removes it once U2 names the label-state owner (RQ-U2-TRANSITION).
  C9-T09 does not list it yet. Confirm this, or assign it elsewhere.
- **G-2:** the `{:github, :rate_limited, detail}` error shape that C7-T08 moves
  unchanged should be typed. The proposed home is U5's typed outcomes. No C9 ticket
  takes it.

## Research questions raised

| ID | Question | Blocks | Who resolves it |
|---|---|---|---|
| RQ-U2-TRANSITION | Who owns a ticket transition? This is the prior program's open question (`synthesis/open-questions.md:9`). | C9-T06, C9-T09 | U2 / coordinator |
| RQ-U6-STATUS-MODEL | U6's shared status read model for the CLI and the web. | C9-T14 | U6 |
| RQ-C8-1 | Should "commands not installed" leave dispatch open, unlike "unavailable", which holds it? | C8-T01/T02 wording | MP-E2 + DESIGN-R1 |
| DESIGN-R1 S4 | Whether the API-without-pages run shape gets an operator flag, and its name. | C6-T04 | Kevin |

Questions answered during this research:

- **RQ2** (`plan.md` §10): a VitePress 1.6.4 data loader can read the root
  `components.json`. The evidence is in C10-T02, and the copy fallback is not needed.
- Phoenix route composition: macros are used, not `forward`. The evidence is in C6-T01.
- A C7 draft said `src/lib/aiur/config.ex` had no U8 ledger row. That was wrong: the
  row is `assignments.csv:65`, package `CONFIG`. C7-T02 is corrected.

## Corrections this research makes to the component map

Recorded in plan.md §9 and in the tickets. `component-map.md` §3 still needs the
coordinator's edit:

- **New component `pr-lifecycle`** (L3, optional). Requires tracker, github, config,
  kernel and signal (C9-T05).
- **New component `ticket-context`.** It holds the 15 `build_order/ticket_detail*` and
  `ticket_history*` files, which serve every ticket's dashboard dialog (C8-T08).
- **`commands` is required, not optional**, because the dispatch gate fails closed
  (CR-C8-3).
- **File placement:**
  - `current_run_membership/**` belongs to orchestration (U2).
  - `open_ticket_source*` belongs to github.
  - `live_conversation*` belongs to agent-runner.
  - `AgentGitHubGuard` belongs to github, not agent-sandbox (C7, C8).
- **Count:** the census finds 99 files outside `github/` that reference `Aiur.GitHub`,
  across 42 modules. The prior survey counted 64. C7-T06 freezes the 42 as the facade
  list.
- **Deferred, with no ticket:**
  - Moving the CI poll into a listener waits for C9-T09.
  - Moving the candidate poll out of the orchestrator process changes timing. It is
    gated on the gap study, so it is not refactor work.
