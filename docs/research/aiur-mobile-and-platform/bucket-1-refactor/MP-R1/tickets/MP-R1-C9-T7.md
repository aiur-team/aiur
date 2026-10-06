---
ticket_id: MP-R1-C9-T7
feature_id: MP-R1
chunk_id: MP-R1-C9
bucket: 1-refactor
title: Orchestrator.State field-owner table, owner map in code, and a write-site ratchet test
status: blocked   # research complete; only DESIGN-R1 and named predecessors remain
blocked_by: [DESIGN-R1, MP-R1-C1-T1, MP-E1-C1]
prior_units: [U2, U6, U8]
prior_boundaries: [ORC #12, DSP #13, CTL #14, PRL #15, MSG #16, ING #9]
prior_features: []
prior_findings: [orch-b-12, tests-1c-07, orch-b-32]
size_owner: LIFECYCLE_DISPATCH (orchestrator/state.ex, 1,033 lines at base)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C9-T7 — State field owners

## Identity and outcome

- Bucket 1, MP-R1, chunk C9, step S16 (prior §7 step 10: "Give each `State` field one
  owner").
- **User value:** none visible. Every field of `Aiur.Orchestrator.State` gets exactly one
  owning sub-boundary, recorded in code, and a test stops a new module from starting to
  write a field it does not own. This is the precondition for C9-T8/T9 and for any later
  process split of PR lifecycle or messaging.
- **Deliverable:**
  1. `Aiur.Orchestrator.State.Owners` (PROPOSED,
     `src/lib/aiur/orchestrator/state/owners.ex`): `@owners %{field => owner}` and
     `owner/1`, `fields_of/1`. Pure data, no runtime use.
  2. `src/test/aiur/orchestrator/state_owners_test.exs` (PROPOSED): (a) the key set of
     `@owners` equals `Map.keys(%State{}) -- [:__struct__]`; (b) a write-site scan with a
     ratchet allowlist `src/test/support/state_writers_allowlist.exs` (PROPOSED).
- **Non-goals:** no field is moved, renamed or deleted here (dead fields are listed, not
  removed); no transition owner is chosen — fields whose writes are ticket transitions are
  owned by the placeholder `:lifecycle` until U2 names the module (RQ-U2-TRANSITION). The
  table is still useful and enforceable before that, because the placeholder is one owner.

## Dependencies and blockers

- DESIGN-R1 §1; MP-R1-C1-T1 (owner atoms are manifest sub-boundary IDs); MP-E1-C1
  (RC-19: E1's `ClaimProbe` and `note_queued_demand/1` hooks must be on `main` so the
  table records them).
- Not blocked on RQ-U2-TRANSITION (placeholder owner, see above). When U2 lands, a
  one-line change maps `:lifecycle` to U2's module; MP-R1-C11-T2 tracks it.
- Run **after** C9-T1…T4 if they have merged (fewer fields); if not, the listener fields
  are owned by `:github_listeners` and the table shrinks when they move. Concurrent with
  C9-T5, C9-T6, C9-T10–T14.

## Verified starting point (45a290e3)

- `defstruct` at `src/lib/aiur/orchestrator/state.ex:207-348` declares **100** top-level
  fields (106 keyword lines minus six keys nested inside `ci_lifecycle`, `:236-243`). The
  `@type t` (`:15-202`) omits two of them, `contradictory_state_label_tickets` and
  `contradictory_state_label_alert_active` (`:269-270`) — fix the `@type` in this ticket.
- Prior survey: "`State` (1,027 lines, ~96 fields) … make `State` fields owned by named
  sub-boundaries" (`feature-boundaries.md` #12); finding `orch-b-12` ("~100-field god
  struct, running entry an untyped map with ~60 keys written by 16 modules").
- Dead fields: `codex_totals`, `codex_rate_limits` have no production reader
  (`git grep` at base finds them only in `state.ex:135-136,287-288` and tests; finding
  `tests-1c-07`). `rework_attempts` is written and read only inside `state.ex:992,1014`
  (helpers called by `ReworkGate`).
- MP-E1-C1 (RC-11/RC-19, `bucket-2-platform/MP-E1/chunks.md` C1-T5): `ClaimProbe`
  **reads** `running`, `claimed`, `retry_attempts`, `auto_resume` inside the orchestrator
  call, and `notify_demand/1` delegates to `note_queued_demand/1`, which **writes**
  `queued_demand_hints`. The build queue writes `agent:todo` through the label-writer
  seam, not through `State` (RC-20).

## Chosen design — the table

Owner atoms are sub-boundaries of the `orchestration` component (prior codes in
brackets). "Readers" lists modules outside the owner that read the field at the base
(from `git grep` of the field name over `src/lib`); readers are allowed, writers are not.

| Owner | Fields | Notable outside readers |
|---|---|---|
| `:core` [ORC] — poll cycle, snapshot, tracker health | `poll_interval_ms`, `effective_poll_interval_ms`, `idle_poll_backoff`, `snapshot_key`, `snapshot_generation`, `next_poll_due_at_ms`, `poll_check_in_progress`, `poll_frozen`, `tick_timer_ref`, `tick_token`, `initial_dispatch_cycle`, `snapshot_ready?`, `candidate_snapshot_fresh?`, `poll_cycles_completed`, `last_dispatch_poll_at_ms`, `last_polled_issues`, `running_issue_cache`, `github_connectivity`, `github_poll_delays`, `queued_demand_hints` (writer also `note_queued_demand/1`, called by MP-E1 `ClaimProbe.notify_demand/1` — sanctioned, RC-19), `waiting_for_human_episodes`, `tracker_preflight_alert_signature`, `tracker_preflight_alert_resolution_emitted` | `status_report`, `agent_control_cli`, `aiur_web/presenter`, `agent_list/*` |
| `:dispatch` [DSP] — admission, capacity, readiness gates | `max_concurrent_agents`, `session_max_concurrent_agents`, `effective_concurrent_agents`, `load_envelope_state`, `capacity_hold`, `dispatch_hold`, `dispatch_capacity_constraints`, `dispatch_declines`, `dispatch_capacity_sample`, `capacity_starvation`, `fleet_capacity_starvation`, `capacity_starvation_resolution_emitted`, `fleet_capacity_starvation_resolution_emitted`, `todo_over_capacity_alert_active`, `prewarm_blocked_alert_active`, `prewarm_blocked_alert_resolution_emitted`, `prewarm_hold_ticks`, `prewarm_hold_since_ms`, `ci_readiness_checked`, `ci_readiness_unavailable_alerted`, `ci_readiness_check_pid`, `ci_readiness_check_token`, `ci_readiness_retry_at_ms`, `ci_readiness_scope`, `ci_readiness_result`, `blocked_ticket_ids`, `decision_store_unavailable_since_ms`, `decision_store_unavailable_alert_active`, `decision_store_unavailable_alert_resolution_emitted`, `dependency_circular_wait`, `observed_error_alerts`, `observed_error_alert_causes`, `active_attention_topics` | `status_report`, `slots`, `capacity_binding`, `run_telemetry/sampler`, `decision_attention` |
| `:lifecycle` — placeholder for U2's transition owner (RQ-U2-TRANSITION) | `running`, `claimed`, `completed`, `retry_attempts`, `released_claims`, `auto_resume`, `model_fallback_waiting`, `dispatch_recovery`, `startup_claim_reconciliation_complete?`, `startup_claim_reconciliation_failures`, `orphaned_agent_reap_count`, `contradictory_state_label_tickets`, `contradictory_state_label_alert_active` | ~60 modules read `running` (agent list, web, runner, CLI); MP-E1 `ClaimProbe` reads `running`, `claimed`, `retry_attempts`, `auto_resume` (sanctioned read, RC-19) |
| `:control` [CTL] | `globally_paused`, `global_pause`, `control_lifecycle` | `agent_control_cli`, `snapshot_store`, `status_reason`, `waiting_reason`, `operator_messages` |
| `:pr_lifecycle` [PRL] | `ci_lifecycle` (all six nested keys; note `poll_cache` also holds the dispatcher's `:candidate_list_cache`, `dispatcher.ex:546-550` — recorded as an allowlisted dispatch writer, see below), `last_ci_poll_started_at_ms`, `pr_review_seen_at`, `pr_ready_ledger`, `comment_rework_retries`, `rework_attempts`, `rework_attempt_alerted`, `merged_ticket_reconciliations`, `merged_ticket_reconciliation_failures` | `status_report`, `dispatcher` (`:1641` head lookup), `events/github_comments_poller` |
| `:messaging` [MSG] | `queue_store` | `issue_sync`, `retry_engine`, `status_report`, `digest_coalescer` |
| `:accounting` | `agent_totals`, `agent_rate_limits`, `codex_totals` (dead), `codex_rate_limits` (dead) | `status_report`, `aiur_web/presenter`, `control_center_presenter` |
| `:github_listeners` [ING] — only until C9-T1…T4 merge | `events_etag`, `events_last_id`, `firehose_partial_streak`, `firehose_truncation_alert_active`, `firehose_truncation_alert_resolution_emitted`, `github_comments_since`, `github_comment_etags`, `github_comment_issue_updated_at`, `github_comment_issue_list_cache`, `github_comment_poll`, `github_comment_reconcile_targets`, `github_comment_reconcile_timer`, `last_comment_poll_started_at_ms`, `github_command_scan_since` | none outside `comment_polling*`, `command_scan` |

Count check: 23 + 33 + 13 + 3 + 9 + 1 + 4 + 14 = 100.

**Write-site scan (the ratchet).** The test greps every `.ex` under `src/lib` for the
write forms `%{state | <field>:`, `%State{… | <field>:`, `Map.put(state, :<field>`,
`put_in(state.<field>` and `update_in(state.<field>` (variable name `state` or any
`%State{}` binding is matched by `\|\s*<field>:` inside a map-update whose left side
mentions `state`; false positives are cheaper than misses and go to the allowlist with a
reason). For each field it computes the set of writing modules. It fails when a module
outside the owner's member list writes the field and is not in the allowlist. The
allowlist is generated once from the implementation head (expected entries include the
dispatcher's `poll_cache.candidate_list_cache` write and `IssueSync` writes into
dispatch alert latches); entries may only be removed later, like the C1 checker's
ratchet (MP-R1-KD7). Owner member lists (module prefixes) live in `Owners` next to
`@owners`.

**RC-20.** The build queue never appears as a writer of `State`; it is a caller of the
label-writer seam. If an E1 change ever adds a `State` write outside
`note_queued_demand/1`, this test fails — intended.

## Implementation steps

1. Add `owners.ex` with the table above (≈140 lines incl. member lists).
2. Fix `@type t` to include the two missing fields (`state.ex`).
3. Add the test and generate the allowlist from the implementation head; commit both.
4. Add a short `@moduledoc` pointer in `state.ex` to `Owners` (one line; no growth past
   current size — U8).

## Non-happy paths

A field added without an owner fails (a); a new writer fails (b). A field rename in C9-T1…T4
updates `Owners` in the same PR (the test forces it). Regex false positive → allowlist
entry with a reason, reviewed.

## Compatibility and rollout

Test-and-data only; no runtime effect. Rollback: revert.

## Verification

```bash
env -C <checkout>/src HOME="$(mktemp -d)" GITHUB_TOKEN= GH_TOKEN= mise exec -- mix test \
  test/aiur/orchestrator/state_owners_test.exs test/aiur/orchestrator/state_test.exs
```

| Test | Expectation | Fails without |
|---|---|---|
| `state_owners_test "every State field has exactly one owner"` | key sets equal | `owners.ex` (delete one entry → fails with that field named) |
| `state_owners_test "no unlisted module writes a field it does not own"` | passes on the implementation head | the allowlist (empty it → fails listing today's cross-owner writers; proves the scan sees real writes) |
| `state_owners_test "the build queue writes no State field"` | no module under `build_queue/` appears as a writer | (guard for RC-20; passes on the base by construction — label it a regression guard) |

The second test's mutation check is "empty the allowlist and see named failures", which
proves the scan is not vacuous (AGENTS.md: no `assert %{}`-style tests).

## Completion and handoff

- [ ] 100 fields owned; `@type` complete; ratchet allowlist committed.
- [ ] Dead fields listed in the PR body for a later U7 cut (not removed here).
- Docs: none.
- Dependents: C9-T8, C9-T9; U2 maps `:lifecycle`; MP-R1-C11-T2 re-checks the table after
  each C9 merge. size_owner re-resolved at ticket start (RC-23).
