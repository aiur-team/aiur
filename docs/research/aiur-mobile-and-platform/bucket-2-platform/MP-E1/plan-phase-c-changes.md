---
feature_id: MP-E1
part_of: plan.md
date: 2026-10-06
---

# MP-E1 plan — §11 Phase C changes

Moved out of [plan.md](plan.md) in Phase D so the plan stays under 500 lines. The
content is unchanged. It is still part of the plan: where this section and an
earlier section of plan.md disagree, this section wins.

## 11. Phase C changes (2026-10-06)

Ticket research changed these parts of the design. Where this section and an
earlier section disagree, this section wins. Tickets are in
[tickets/README.md](tickets/README.md).

1. **No GitHub code under `build_queue/` (§5.1).** `observer.ex` calls only
   `Aiur.Tracker`. Four optional tracker callbacks carry the observations:
   `open_issue_labels/1` (C1-T03), `blocked_by/1` (C4-T03), `issue_closure/1`
   (C4-T04) and `ticket_pull_request/1` (C4-T05). The GitHub adapter
   implements them; Linear answers `{:error, :unsupported}`
   (`linear/tracker.ex:139-142`), which disables the queue.
2. **Promotion is a conditional write (§5.4, RQ-4, RC-20).**
   `Tracker.update_issue_state(id, "todo", expected_state: :none)`. C1-T04
   adds `:none` to `validate_expected_state/2` (`github/issue_state.ex:170-188`),
   which already re-reads the issue before it writes (`:142-161`).
3. **Sort key (§5.6).** `Hints.sort_key/1` returns `{-downstream_open,
   list_position}`, default `{0, 0}`, spliced into the existing key as
   `{d, priority_rank, position, created_at, identifier}`. Prepending a
   default 1-tuple, as §5.6 said, would be wrong: Erlang orders tuples by size
   first (https://www.erlang.org/doc/system/expressions.html#term-comparisons,
   accessed 2026-10-06).
4. **ClaimProbe is batched (§5.5, RQ-7).** `status([id])` returns
   `:claimed | :unclaimed | {:declined, reason}` per id from one call into the
   orchestrator. The decline comes from `state.dispatch_declines`
   (`orchestrator/state.ex:88`). `:unauthorized` is recorded there only while
   free slots exist (`orchestrator/dispatcher.ex:1054-1070`), so
   `promoted_unauthorized` is detected only then.
5. **Hold reason.** `:build_queue_hold` is added to
   `t:dispatch_decline_reason/0` and `@dispatch_decline_reasons`
   (`dispatch_policy.ex:644-697`) and translated in
   `PauseResume.resume_decline_reason/4` (`pause_resume.ex:2180-2209`), or
   `resume_decline_reason_test.exs:19-51` fails.
6. **Why the heal exemption is mandatory (§5.2, F5).** The conditional poll
   returns every zero-state-label issue as "healable"
   (`github/issues.ex:468-482`). Without the exemption a marker-only item either
   gets `agent:todo` back (prior state known) or raises
   `state-label-missing-no-evidence` on every poll (`issue_sync.ex:392-399`).
7. **Progress owner (RC-10).** A neutral `Aiur.BuildProgress` holds facts, the
   read API and the progress-changed signal. Two producers: the queue server
   and `Aiur.BuildOrder.ProgressObserver`. Milestone topics are
   `system.queue.<id>.progress` and `system.build_order.<root>.progress`
   (RC-08).
8. **Agent-workspace guard (RQ-6).** The `--test` guard is in `scripts/aiurdev`
   (`:538-560, 727-739`), not the shared engine. `aiur queue` mutations copy
   its test (`AIUR_AGENT_WORKSPACE`, set for every agent at
   `agent_environment.ex:339`, or an `*/aiur-workspaces/*` path) in the engine,
   and repeat the env check daemon-side as `test_reset.ex:79-95` does. It is a
   guard, not a security boundary (§6 Authorization still holds).
9. **Wave-0 rules (RC-19, RC-20).** MP-E1 is not gated on U0. Core edits stay
   in the C1 hooks; U2 and U5 tickets rebase over them. The queue is a
   sanctioned caller of the label-writer seam.
10. **Size owners (RC-23).** Tickets record the owner from
    `synthesis/u8-release-007/assignments.csv` as provisional and re-check the
    then-current ledger when they start.
