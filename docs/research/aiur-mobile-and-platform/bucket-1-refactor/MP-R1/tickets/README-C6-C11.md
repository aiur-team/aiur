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

## Ticket table

| ID | Title | Blocked by | Lane |
|---|---|---|---|
| C6-T1 | Split the router into component-owned route modules, kept in a fixed order | C1-T1, C3-T3 | web |
| C6-T2 | Components register their own endpoint sockets | C1-T1 | web |
| C6-T3 | Internal run shape: HTTP listener and JSON API on, dashboard pages off | C6-T1, C3-T1 | web |
| C6-T4 | Operator flag for that run shape | DESIGN-R1 S4, C6-T3 | web |
| C7-T1 | Tracker split into IssueTracker and CodeHost ports | C1-T1, C1-T3, MP-E1-C1 | tracker |
| C7-T2 | Register tracker adapters instead of naming them in a `case` | C7-T1, C4-T1 | tracker |
| C7-T3 | Agent-sandbox boundary (non-GitHub edges) | C1-T1, C1-T3, C5-T2, C5-T3 | sandbox |
| C7-T4 | GitHub parts of the agent environment behind a registered contributor | C7-T3, U5 | sandbox |
| C7-T5 | Workspace boundary | C7-T2, C7-T3, C7-T4, C5-T2, C5-T3 | sandbox |
| C7-T6 | GitHub family as one logical component (KTD11, no new package) | C1-T1/T3/T5, C5-T3, U5, MP-E1-C1 | github |
| C7-T7 | Dispatcher candidate fetch and revalidation go through the tracker facade | C7-T1, C7-T2, C7-T6, U2, MP-E1-C1 | github |
| C7-T8 | CI-readiness gate leaves Dispatcher; its last direct GitHub calls go | C7-T6, C7-T7, U2, U5, MP-E1-C1 | github |
| C8-T1 | `Aiur.Commands` facade and migration of outside callers | C1-T1/T3/T5 | commands |
| C8-T2 | Answer delivery goes through an orchestration-provided delivery-target port | C8-T1, U6 journal matrix | commands |
| C8-T3 | Projections: Units row model and policy leave the web namespace | C1-T1/T3/T5 | projections |
| C8-T4 | Projections: remaining edges and manifest reassignments | C8-T3, #3009 fixed or deferred | projections |
| C8-T5 | Display sanitizer moves from build-orders to kernel | C1-T1/T3/T5 | conv/BO |
| C8-T6 | `Aiur.Conversations` read facade | C8-T5, MP-R6-C1, C1-T3 | conv/BO |
| C8-T7 | Remove GitHub's references into build-order modules | C1-T3/T5, U5 | conv/BO |
| C8-T8 | Build-orders facades, component-owned child specs, new `ticket-context` component | C8-T5, C8-T7, C5-T2, U2 graph contract | conv/BO |
| C8-T9 | Build queue moves from its wave-0 seam to its final shape | MP-E1 C1–C7, C1-T3/T5, C5-T3, C3-T1, C8-T8, MP-E1 owner review | conv/BO |
| C9-T1 | GitHub listener supervisor; firehose cursor fields leave `Orchestrator.State` | C1-T1/T2, C7-T6, MP-R2-C2-T08, U5, MP-E1-C1 | listeners |
| C9-T2 | Comment poll reads plain inputs and a cursor struct, not `State` | C9-T1, MP-R2-C2-T08, MP-E1-C1 | listeners |
| C9-T3 | Comments listener process owns the comment-poll cursor | C9-T1, C9-T2, MP-E1-C1 | listeners |
| C9-T4 | Command-scan listener | C9-T2, C9-T3, MP-E1-C1 | listeners |
| C9-T5 | `PRHealthScanner` moves into `pr-lifecycle` | C1-T1/T2 | pr-lifecycle |
| C9-T6 | `ReworkRequeue` moves into `pr-lifecycle` | **RQ-U2-TRANSITION**, U2, C9-T5, C1-T2 | pr-lifecycle |
| C9-T7 | `Orchestrator.State` field-owner table and a write-site ratchet test | C1-T1, MP-E1-C1 | core |
| C9-T8 | Remove facade back-calls that are not transitions | C9-T7, C1-T2, MP-E1-C1 | core |
| C9-T9 | Transition back-calls return effects to U2's lifecycle owner | **RQ-U2-TRANSITION**, U2, C9-T7, C9-T8, MP-E1-C1 | core |
| C9-T10 | Control-CLI kernel: output protocol and reason renderer | C1-T1/T2 | cli |
| C9-T11 | Executor verbs move to executor-attention | C9-T10, U3 | cli |
| C9-T12 | Control verbs move to orchestration's control CLI | C9-T10, C9-T11 | cli |
| C9-T13 | `--todo` verb moves; MP-E1's `queue` verb stays on its own module | C9-T10, C9-T12 | cli |
| C9-T14 | Read verbs move after U6's shared status model | U6, **RQ-U6-STATUS-MODEL**, C9-T10, C9-T13 | cli |
| C10-T1 | Public manifest fields and the generated planned-features list | C1-T1; DESIGN-R1 §3 Q4/Q5 for `public` flags | directory |
| C10-T2 | Build-time VitePress data loader and an unlisted placeholder page | C10-T1 | directory |
| C10-T3 | Render the page to the approved DESIGN-R1 design | DESIGN-R1 §3 (layout, Q1, Q3, Q4, Q6–Q8, copy), C10-T2 | directory |
| C10-T4 | Docs-sync rules that also run on docs-only PRs; docs rebuild when the manifest changes | C1-T1, C10-T1 | directory |
| C10-T5 | Publish: sidebar entry, AGENTS.md row, go-live | DESIGN-R1 §3 final approval, C10-T3, C10-T4, all of C9, C11-T3 | directory |
| C11-T1 | Plan-refresh tool: path map, stale citations and size owners (research branch) | C1-T1 | refresh |
| C11-T2 | Plan refresh after each move, and size-owner lookup at ticket start (RC-23 runbook) | C11-T1 | refresh |
| C11-T3 | Final plan refresh before wave 2 and before the page goes live | C11-T2, all of C9 | refresh |

## Dependency order inside C6–C11

```text
web:          C6-T1 ─┬─> C6-T3 ─> C6-T4          C6-T2 (independent)
tracker:      C7-T1 ─> C7-T2 ─┐
sandbox:      C7-T3 ─> C7-T4 ─┴> C7-T5           (MP-R7 starts after C7-T3/T4)
github:       C7-T6 ─> C7-T7 ─> C7-T8            (C7-T7 also needs C7-T1/T2)
commands:     C8-T1 ─> C8-T2
projections:  C8-T3 ─> C8-T4
conv/BO:      C8-T5 ─> C8-T6;  C8-T7 ─> C8-T8 ─> C8-T9   (C8-T8 also needs C8-T5)
listeners:    C9-T1 ─> C9-T2 ─> C9-T3 ─> C9-T4   (C9-T1 needs C7-T6)
pr-lifecycle: C9-T5 ─> C9-T6
core:         C9-T7 ─> C9-T8 ─> C9-T9
cli:          C9-T10 ─> C9-T11 ─> C9-T12 ─> C9-T13 ─> C9-T14
directory:    C10-T1 ─> C10-T2 ─> C10-T3 ─┐
              C10-T1 ─> C10-T4 ───────────┴> C10-T5 (after all of C9 and C11-T3)
refresh:      C11-T1 ─> C11-T2 (recurring) ─> C11-T3 (after all of C9)
```

## What can run at the same time

- **First tickets that can start** once DESIGN-R1 and C1-T1 are done: C6-T2, C7-T1,
  C7-T3 (also needs C5-T2/T3), C8-T1, C8-T3, C8-T5, C9-T5, C9-T7, C9-T10, C10-T1 and
  C11-T1. These lanes do not touch the same files.
- **Lanes that share files and must merge in series:**
  - C6-T1 and C3-T3 both edit `router.ex`. Merge C3-T3 first.
  - C7-T3, C7-T4 and C7-T5 share sandbox files.
  - C9-T1 to C9-T4 must wait behind MP-R2-C2-T08, which edits the same files.
  - The C9-T10 to C9-T14 merges all touch `agent_control_cli.ex`. The work can overlap.
  - C7-T7/T8 and C9-T7/T8/T9 all touch `dispatcher.ex` and `state.ex`. Run C7-T7/T8
    first, then C9-T7.
- **C10-T2, C10-T3 and C10-T4** can be developed against fixtures while the moves
  continue. Only C10-T5 waits for the end of the refactor (D20).
- Running in parallel during research does not mean the tickets can be implemented in
  parallel. Each ticket names its predecessors.

## Binding decisions applied

- **RC-19 / RC-20:** every ticket that touches `issue_sync.ex`, `dispatch_policy.ex`,
  `github/labels.ex` or `github/issues.ex` is listed with `MP-E1-C1` in its blockers.
  That covers C7-T1, C7-T6, C7-T7, C7-T8, C8-T9 and C9-T1 to C9-T4, C9-T7 to C9-T9.
  Each one rebases over E1-C1 and has a test that the hooks survive. The queue is a
  sanctioned caller of the single label-writer seam. C8-T9, C9-T7 and C9-T9 have
  guard tests for this.
- **RC-23:** every ticket says that its `size_owner` is looked up again at ticket start,
  in the current U8 ledger. The procedure is MP-R1-C11-T2 Procedure B, and the
  MP-R1-C11-T1 tool automates the lookup.
- **RC-11:** C8-T9 keeps the rank-and-hold lookup in `DispatchPolicy` and the
  claim-check interface.
- **RC-06 / RC-07:** C8-T6 builds on MP-R6-C1's neutral anchor module and does not
  extract it again.
- **RC-21:** C7-T6 cites "U5 first".
- **KTD11:** C7-T6 creates a logical manifest component only, with no package, process
  or new facade module.

## How these tickets map to the plan.md §9 ticket lists

The plan's provisional ticket lists were refined with evidence. When the plan's ID and
the ticket ID differ, use the ticket ID.

| Plan §9 (old) | Tickets |
|---|---|
| C6 T1–T4 | C6-T1 to T4 (same meaning; T4 is the operator flag, blocked on S4) |
| C7 T1–T6 | T1 split, T2 registration, T3 sandbox, T4 sandbox GitHub contributor, T5 workspace, T6 GitHub component; the old T6 "Dispatcher" became T7 and T8 |
| C8 T1–T5 | T1/T2 Commands, T3/T4 projections, T5/T6 conversations, T7/T8 build-orders, T9 build queue |
| C9 T1 listeners | C9-T1 to T4 |
| C9 T2 PRHealthScanner / ReworkRequeue | C9-T5, C9-T6 |
| C9 T3 state-field owners | C9-T7 (and C9-T8) |
| C9 T4 effects | C9-T9 |
| C9 T5 CLI split | C9-T10 to T14 |
| C10 T1–T4 | C10-T1 to T5 (T2 was split into the loader, T2, and the approved design, T3) |
| C11 T1–T3 | C11-T1 to T3 (same) |

## Requests to the C1–C5 researcher (cross-chunk, inside MP-R1)

- **Q-1 (from C7-T5):** MP-R1-C5-T2 must also move the `reap_*` and
  `process_group_alive?` helpers (`src/lib/aiur/claude/remote_control.ex:266-354`).
  Moving only the graceful-kill helpers is not enough, because C7-T5 depends on all of
  them.
- **Q-2 (from C10-T1, C10-T4):** `components.schema.json` must accept the top-level
  `features` array and the `directory_published` flag that C10-T1 and C10-T4 add. The
  simplest form: the root object allows those two keys.
- **Q-3 (from C10-T4):** the ticket ID of the `packages/aiur-contracts` capability
  schema is plan C3-T6. If the final ID differs, C10-T1 and C10-T4 cite the plan ID and
  must be updated.
- **Q-4 (from C8-T8):** `src/lib/aiur/github/issues.ex` references
  `BuildOrder.Bounded`; C5-T2 owns moving it. `config.ex` references
  `BuildOrder.Cadence`; C4 owns that.

## Open items with no owner yet (for the coordinator)

- **G-1:** the `GitHub.Issues → Orchestrator.DispatchPolicy` edge
  (`src/lib/aiur/github/issues.ex:23,952,1132`) stays in the allowlist. C7-T6 proposes
  that C9-T9 removes it once U2 names the label-state owner (RQ-U2-TRANSITION).
  C9-T9 does not list it yet. Confirm this, or assign it elsewhere.
- **G-2:** the `{:github, :rate_limited, detail}` error shape that C7-T8 moves
  unchanged should be typed. The proposed home is U5's typed outcomes. No C9 ticket
  takes it.

## Research questions raised

| ID | Question | Blocks | Who resolves it |
|---|---|---|---|
| RQ-U2-TRANSITION | Who owns a ticket transition? This is the prior program's open question (`synthesis/open-questions.md:9`). | C9-T6, C9-T9 | U2 / coordinator |
| RQ-U6-STATUS-MODEL | U6's shared status read model for the CLI and the web. | C9-T14 | U6 |
| RQ-C8-1 | Should "commands not installed" leave dispatch open, unlike "unavailable", which holds it? | C8-T1/T2 wording | MP-E2 + DESIGN-R1 |
| DESIGN-R1 S4 | Whether the API-without-pages run shape gets an operator flag, and its name. | C6-T4 | Kevin |

Questions answered during this research:

- **RQ2** (`plan.md` §10): a VitePress 1.6.4 data loader can read the root
  `components.json`. The evidence is in C10-T2, and the copy fallback is not needed.
- Phoenix route composition: macros are used, not `forward`. The evidence is in C6-T1.
- A C7 draft said `src/lib/aiur/config.ex` had no U8 ledger row. That was wrong: the
  row is `assignments.csv:65`, package `CONFIG`. C7-T2 is corrected.

## Corrections this research makes to the component map

Recorded in plan.md §9 and in the tickets. `component-map.md` §3 still needs the
coordinator's edit:

- **New component `pr-lifecycle`** (L3, optional). Requires tracker, github, config,
  kernel and signal (C9-T5).
- **New component `ticket-context`.** It holds the 15 `build_order/ticket_detail*` and
  `ticket_history*` files, which serve every ticket's dashboard dialog (C8-T8).
- **`commands` is required, not optional**, because the dispatch gate fails closed
  (CR-C8-3).
- **File placement:**
  - `current_run_membership/**` belongs to orchestration (U2).
  - `open_ticket_source*` belongs to github.
  - `live_conversation*` belongs to agent-runner.
  - `AgentGitHubGuard` belongs to github, not agent-sandbox (C7, C8).
- **Count:** the census finds 99 files outside `github/` that reference `Aiur.GitHub`,
  across 42 modules. The prior survey counted 64. C7-T6 freezes the 42 as the facade
  list.
- **Deferred, with no ticket:**
  - Moving the CI poll into a listener waits for C9-T9.
  - Moving the candidate poll out of the orchestrator process changes timing. It is
    gated on the gap study, so it is not refactor work.
