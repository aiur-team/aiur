---
ticket_id: MP-R1-C8-T9
feature_id: MP-R1
chunk_id: MP-R1-C8
bucket: 1-refactor
title: Move the build queue from its wave-0 seam to its final component shape
status: blocked
blocked_by: [DESIGN-R1, "MP-E1 C1–C7 merged (ticket IDs per MP-E1 README; incl. MP-E1-C1-T05 Hints hook, MP-E1-C1-T06 ClaimProbe, MP-E1-C1-T07 seam test)", MP-R1-C1-T3, MP-R1-C1-T5, MP-R1-C5-T3 (Signal.emit), MP-R1-C3-T1 (capability registry), MP-R1-C8-T8, "MP-E1 owner review"]
prior_units: [U2, U3, U5]
prior_boundaries: [BO #30, ORC #12, DSP #13, CLI #31, WEB #34, BUS #10]
prior_features: [MP-E1]
prior_findings: []
size_owner: LIFECYCLE_DISPATCH (dispatch_policy.ex, issue_sync.ex — hooks preserved, not edited) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T2. build_queue/ files are new in MP-E1 and must each be ≤500 lines.
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C8-T9 — Build queue final component shape

## Identity and outcome

- **Bucket / feature / chunk:** 1-refactor / MP-R1 / C8 (step S13, path-map row PR-11).
- **User value:** none visible. The queue that MP-E1 shipped before the refactor
  (D2) becomes a checked component: the checker replaces E1's hand-written seam test,
  attention goes through the signal port, and clients detect the queue through the
  capability report.
- **Deliverable:**
  1. `components.json` `build-queue` entry finalised (`status: optional`, layer L3,
     facades `Aiur.BuildQueue`, `Aiur.BuildQueue.Hints`, `Aiur.BuildQueue.ClaimProbe`
     (behaviour), requires `tracker`, `event-bus`, `config`, `identity`, `signal`;
     optional `build-orders` (only from `sources/build_order.ex`)).
  2. The two narrow orchestration edges (RC-11, E1 X-1) declared: orchestration →
     `Aiur.BuildQueue.Hints` (optional; neutral values when absent) and the
     orchestration implementation `Aiur.Orchestrator.BuildQueueClaimProbe` bound by
     `config :aiur, :build_queue_claim_probe` (composition, not a code edge).
  3. `build_queue/attention.ex` switches from `Aiur.Alerts` to `Signal.emit/2`
     (plan-refresh row PR-07), with identical alert payloads.
  4. The queue registers capabilities `build_queue` and `build_queue.build_order_source`
     with the MP-R1-C3 registry.
  5. E1's source-scan test (`test/aiur/build_queue/seam_test.exs`, MP-E1-C1-T07) is
     retired **only after** the checker carries the same three rules with failing
     fixtures (RC-11 "R1-C1 absorbs it later").
- **Non-goals:** no change to queue behaviour, ordering, promotion, withdrawal, label
  writes or progress milestones; no package extraction (promotion test §5 not yet met);
  no dashboard view (MP-E1-C8).

## Dependencies and blockers

- **MP-E1 must have shipped.** At `45a290e3` no `src/lib/aiur/build_queue/` exists
  (`git ls-tree -r 45a290e3 -- src/lib/aiur | grep build_queue` is empty). This ticket
  is written against MP-E1's planned seam (`bucket-2-platform/MP-E1/plan.md` §5.1) and
  its C1 tickets; the implementer re-verifies every path against the merged E1 code via
  the MP-R1-C11 refresh before starting.
- **RC-19:** E1 edits U2 files (`issue_sync.ex`, `dispatch_policy.ex`) and U5 files
  (`github/labels.ex`, `github/issues.ex`) only through its C1 hooks. This move must
  preserve those hooks unchanged, with an explicit test (below).
- **RC-20:** the queue is a sanctioned caller of the single label-writer seam. Before
  U2 it calls the existing writer (`Aiur.Tracker.update_issue_state/3` →
  `GitHub.IssueState`, per MP-E1-C1-T04); after U2, U2's writer. This move must not
  add a second label-writing implementation.
- MP-R1-C5-T3 (`Signal.emit/2` exists), MP-R1-C3-T1 (registry), MP-R1-C8-T8
  (`build-orders` facades declared so `sources/build_order.ex` references a facade).
- MP-R2: if the R2 bus package has moved `Aiur.Events.Exchange`, the queue's subscribe
  call follows R2's facade (row PR-01). RC-08 topics (`ticket.<id>.queue.*`,
  `system.queue.*`, `system.build_order.<root>.progress`) are registered by MP-R2-C5,
  not here.
- MP-E1 owner review is required on the PR (migration-plan S13).

## Verified starting point (45a290e3 + MP-E1 plan)

- No queue code at base. Planned layout (MP-E1 plan §5.1): `build_queue/{model,readiness,ordering,planner,store,server,observer,claim_probe,hints,attention,progress}.ex`,
  `build_queue/sources/{executor_list,build_order}.ex`, `build_queue_cli.ex`,
  `aiur_web/live/build_queue_live.ex`.
- Planned seam rules (component-map §4): no `Aiur.Orchestrator.*` or `Aiur.GitHub.*`
  under `build_queue/`; `Aiur.BuildOrder.*` only in `sources/build_order.ex`; readiness
  through `Aiur.Tracker`; attention through one function calling `Aiur.Alerts`.
- Planned E1 tests that guard the hooks: `test/aiur/orchestrator/dispatch_policy_test.exs`
  (no Hints table → today's sort; rank and hold behaviour; MP-E1-C1-T05),
  `test/aiur/build_queue/claim_probe_test.exs` and
  `test/aiur/orchestrator/build_queue_claim_probe_test.exs` (MP-E1-C1-T06),
  `test/aiur/github/issue_state_test.exs` (MP-E1-C1-T04), `test/aiur/build_queue/seam_test.exs` (MP-E1-C1-T07).
- Alert side effects today: `Aiur.Alerts` writes up to four files and three
  broadcasts per alert (prior research §6); C5-T3 owns preserving that order behind
  `Signal.emit/2`.

## Chosen design

- **Manifest-first, code-minimal.** E1 was built on the seam, so the move is:
  manifest entry, two declared edges, one call-site change in `attention.ex`, one
  capability callback module, and test migration.
- **Capability callback:** PROPOSED `build_queue/capability.ex` implementing the
  MP-R1-C3 callback behaviour: `build_queue` = `available` when the queue server is
  running, `unavailable/not_running` otherwise; `build_queue.build_order_source` =
  `available` only when the `build_orders` capability is available (never inferred
  from an empty queue).
- **Seam test retirement rule:** delete `seam_test.exs` in the same PR only if
  `check-components.py` has, for `build-queue`, (a) a private/undeclared edge rule
  that fails on a fixture referencing `Aiur.Orchestrator.State`, (b) one failing on
  `Aiur.GitHub.Labels`, (c) one failing on `Aiur.BuildOrder.Graph` outside
  `sources/build_order.ex`. Otherwise keep the test and say so.

## Implementation steps

1. Refresh: list every `Aiur.*` reference under `build_queue/` at head; any reference
   that is not a declared facade is a stop-and-report, not a fix-in-passing.
2. Write the `build-queue` manifest entry and the two orchestration edges.
3. `attention.ex`: replace the `Aiur.Alerts` call with `Signal.emit/2` (same
   payload; ≈5 lines).
4. Add `build_queue/capability.ex` and register it (≈40 lines).
5. Add the checker fixtures (if C1-T6 did not already include build-queue rules) and
   retire `seam_test.exs` per the rule above.

## Non-happy paths

- **Queue server down:** `Hints` returns neutral values (rank `{0}`, no hold) — E1
  behaviour; the capability reads `unavailable/not_running`; dispatch continues.
- **Orchestrator down:** ClaimProbe returns `:unavailable`; withdrawal waits (E1
  §5.5). Unchanged.
- **Build orders absent:** `build_queue.build_order_source` is `unavailable`; the
  executor-list source keeps working (D5).
- **Signal port failure:** whatever C5-T3 specifies for sink failure; the queue does
  not add its own fallback to `Aiur.Alerts`.

## Compatibility and rollout

No config change, no change to `.aiur/config` `build_queue.*` keys or the queue journal
under its `Config.Paths` key. Rollback: revert (the seam test returns with it).

## Verification

- **RC-19 hook-preservation test** (new, `test/aiur/build_queue/hooks_preserved_test.exs`):
  `test "dispatch order without the hints table equals the pre-queue order"` — the
  E1-C1-T05 20-issue fixture run through `DispatchPolicy.sort_issues_for_dispatch/1`
  with the Hints table deleted; `test "a held item is skipped with :build_queue_hold"`;
  `test "queued marker plus agent:todo parses to one state label"` (labels). These
  re-run E1's hook contracts after the move. **Mutation:** remove the
  `{:skip, :build_queue_hold}` clause from `DispatchPolicy` → second test fails.
- **RC-20 single-writer test:** `test "promotion writes agent:todo through the tracker state writer"`
  — inject a recording tracker; assert the only label write goes through
  `Aiur.Tracker.update_issue_state/3` (or U2's writer at head). **Mutation:** a direct
  `Aiur.GitHub.Labels` call in the planner → checker fails and this test sees no
  tracker call.
- `test "attention goes through Signal.emit with the E1 payload"` (capture sink).
  **Mutation:** restore the `Aiur.Alerts` call → captured sink is empty.
- `test "build_queue capability reports not_running when the server is stopped"`;
  **Mutation:** return `available` unconditionally → fails.
- Commands:
  `env -C src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test test/aiur/build_queue test/aiur/orchestrator/dispatch_policy_test.exs test/aiur/orchestrator/build_queue_claim_probe_test.exs test/aiur/github/issue_state_test.exs test/aiur/github/labels_test.exs`;
  `make -C src fmt-check lint`; `python3 scripts/check-components.py`;
  `bash scripts/test-check-components.sh` (fixtures).
- Manual (AGENTS.md): foreground `scripts/aiurdev --test`; `aiurdev queue show`
  (verb per MP-E1-C6) and `aiurdev capabilities` (MP-R1-C3) before/after; queue output
  identical; capability lists `build_queue available`.

## Completion and handoff

- [ ] `build-queue` manifest entry final; checker clean for it; count ≤ baseline.
- [ ] E1 hook tests and the RC-19/RC-20 tests pass; mutations fail.
- [ ] Seam test retired or retained with a stated reason.
- **Docs:** none for behaviour. If the capability IDs are new to the
  `concepts` capabilities section (MP-R1-C3-T7), add the two rows there in this PR.
- **Dependents:** MP-N3, MP-N5 (read the queue through its facade/capability);
  MP-R1-C9 (orchestration core keeps Hints/ClaimProbe as the only queue edges);
  MP-E1 plan §10 refresh table rows marked done by MP-R1-C11.
