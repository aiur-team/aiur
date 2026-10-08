---
ticket_id: MP-R1-C9-T08
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Remove non-transition facade back-calls (sub-modules call their sibling owner directly)
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C9-T07, MP-R1-C1-T02, MP-E1-C1]
prior_units: [U2, U8]
prior_boundaries: [ORC #12, DSP #13, CTL #14, PRL #15, MSG #16]
prior_features: []
prior_findings: [orch-a-06, orch-b-11, loose-2-24, orch-a-23]
size_owner: LIFECYCLE_DISPATCH (orchestrator.ex, issue_sync.ex, comment_wake.ex, comment_polling.ex, dispatcher.ex, state.ex); LIFECYCLE_STATUS (reconciler.ex, pause_resume.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T08 — Facade back-calls, part 1 (no transitions)

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S16 (prior §7 step 10 "make sub-modules return effects
  instead of calling back into the `Orchestrator` facade"; this ticket is the half that
  needs no effect type).
- **User value:** none visible. Removes the sub-module → `Aiur.Orchestrator` →
  sibling-module cycle for every back-call that is **not** a ticket transition (findings
  `orch-a-06`, `orch-b-11`: "Submodules call back into the Aiur.Orchestrator facade, which
  only forwards to their siblings").
- **Deliverable:** each listed call site calls the sibling that implements the function;
  the facade delegates that then have no caller are deleted; pure helpers defined in
  `orchestrator.ex` move to their owner.
- **Non-goals:** transition back-calls (`resume_paused_issue`, `terminate_running_issue`,
  `reactivate_issue`, `transition_control_status`, `pause_issue_for_ci_wait`,
  `maybe_deactivate_human_review_issue`, `preserve_running_issue_on_external_error`) — those
  are C9-T09, blocked on RQ-U2-TRANSITION. No behaviour change: every replaced call is a
  pure forward in the same process.

## Dependencies and blockers

- DESIGN-R1 §1; C9-T07 (owner table names the sibling owners); MP-R1-C1-T02 (rule
  "orchestration sub-module → `Aiur.Orchestrator` facade" is a recorded violation so the
  ratchet shows the drop); MP-E1-C1 (RC-19: rebase over E1's `issue_sync.ex` hooks and keep
  them).
- If C9-T01…T04 merged first, the `comment_polling.ex` call sites are already gone; skip them.
- Concurrent with C9-T05, C9-T06, C9-T10–T14.

## Verified starting point (45a290e3)

Facade functions in `src/lib/aiur/orchestrator.ex` and the sibling they forward to:

| Facade (line) | Implementation | Back-call sites (count) |
|---|---|---|
| `note_github_connectivity_success/2` (`:260-262`), `note_github_connectivity_failure/3` (`:265-267`), `note_github_poll_interval/3` (`:281-283`) | `TrackerHealth` | `comment_polling.ex` (9), `tracker_health.ex` (1) |
| `connectivity_detail/1` (`:271-273`, defined in the facade) | moves to `TrackerHealth` | 1 |
| `running_worker_host/2` (`:983-…`, defined in the facade; reads `state.running`) | moves to `State` | 8 |
| `schedule_poll_cycle_start/0` (`:981`) | `Lifecycle` | 3 |
| `enqueue_event_digest_item/4` (`:927-928`) | `OperatorMessages` | 3 |
| `cancel_ci_wait_rewake/2` (`:384`) | `CiLifecycle` | 3 |
| `refresh_tracked_set/1` (`:40`) | `TrackedSet` | 1 |
| `clear_session_handle/1` (`:394`) | `WorkspaceCleanup` | 1 |
| `kill_repl_session/1` (`:406`), `close_active_chat_streams/2` (`:408-409`), `terminate_task/1` (`:412`) | `AgentTeardown` | 3 |
| `reconcile_overrunning_agents/1` (`:414-415`), `reconcile_stalled_running_issues/1` (`:418-419`), `reconcile_runtime_health/1` (`:422`) | `RuntimeWatchdog` | 3 |
| `reconcile_pending_auto_resumes/1` (`:386-387`) | `PushRouting` | 1 |

Call sites by file (`git grep` at base, `Orchestrator.<name>` for the names above): 
`agent_teardown.ex` 2, `comment_polling.ex` 9, `comment_wake.ex` 7, `dispatcher.ex` 1,
`issue_sync.ex` 7, `pause_resume.ex` 1, `pr_anchored.ex` 1, `reconciler.ex` 5,
`remote_control_mode.ex` 3, `tracker_health.ex` 1 (37 total). **No caller outside
`src/lib/aiur/orchestrator/` and no test calls these names** (same grep over `src/`), so
each delegate can be deleted after its sites move.

## Chosen design

Mechanical replacement `Orchestrator.f(args)` → `Sibling.f(args)`; aliases adjusted. Two
pure helpers move: `connectivity_detail/1` to `TrackerHealth`, `running_worker_host/2` to
`State` (it reads only `state.running`; owner `:lifecycle` field, read-only use). Delete
the 17 facade entries that have no remaining caller (finding `loose-2-24`: "~100
delegates including dead entries").

**Invariant:** after this ticket, `git grep -E 'Orchestrator\.(<17 names>)\b' -- src`
returns nothing, and the checker's "sub-module → facade" violation count drops by the
number of files that no longer reference the facade at all.

## Implementation steps

1. Move `connectivity_detail/1` and `running_worker_host/2` (≈20 lines).
2. Replace 37 call sites file by file; add aliases.
3. Delete the dead facade entries and their `@spec`s from `orchestrator.ex` (shrinks it;
   U8 LIFECYCLE_DISPATCH benefit).
4. Update the checker allowlist (`components.json`) by removing the entries this fixes.

Estimated: ≈120 changed lines.

## Non-happy paths

None new: each call ran in the orchestrator process before and after; no message,
timeout or error path changes. Risk is a wrong sibling — guarded by the full orchestrator
suite on the merge ref (memory: CI builds the merge ref).

## Compatibility and rollout

Internal only; no config/API. Rollback: revert.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator test/aiur/orchestrator_status_test.exs \
  test/aiur/orchestrator_deactivate_test.exs test/aiur/orchestrator_ci_lifecycle_test.exs
env -C <checkout>/src mise exec -- mix compile --warnings-as-errors
python3 scripts/check-components.py
```

| Test | Expectation | Fails without |
|---|---|---|
| `orchestrator_facade_test "no orchestration sub-module calls the 17 removed facade names"` (source scan over `src/lib/aiur/orchestrator/**`) | zero matches | any one call-site replacement (revert one → one match reported) |
| `state_test "running_worker_host/2 returns the entry's worker_host or nil"` | moved function behaviour, table of 3 cases | the move (compile error → red) |

The checker ratchet number before/after goes in the PR body. Full CI on the head SHA is
required (memory: narrow test runs hide supervision bugs). Manual: wrapper-tmux
`aiurdev --test` smoke — open a chat pane, send a message, see it delivered (exercises
`enqueue_event_digest_item` and teardown paths).

## Completion and handoff

- [ ] 37 sites moved; 17 delegates deleted; checker count reduced.
- Docs: none.
- Dependents: C9-T09. size_owner re-resolved at ticket start (RC-23, MP-R1-C11-T02).
