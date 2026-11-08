---
title: Resume workers for durable Command overrides
type: feat
execution: code
---

# Goal

Implement #6909 on the merged #6908 contract. An unmerged ticket's override
wakes its existing worker or starts a continuation on the same ticket when
capacity permits. No new work ticket or PR is created.

## Decisions and implementation units

1. Use the Decision journal's override records as the durable resume table,
   keyed by action/override ID. Add an additive resume-state fact for changing
   routes and reasons. Only the current action qualifies; older revisions are
   already superseded. Keep capacity waits visible in public override records.
   Files: `src/lib/aiur/commands/overrides.ex`, `commands/event_data.ex`,
   `commands/projection.ex`, `decision_store/overrides.ex`, `decision_store/settlement.ex`.
2. Add `src/lib/aiur/orchestrator/override_resume.ex`, driven by candidate polls.
   Read pending records and refresh tickets/PRs off the orchestrator mailbox;
   apply in oldest-request order within that mailbox. Reuse resume policy,
   fleet reservations, effective limits and PressureAdmission. Revalidate labels
   before waking; an explicit park/pause raises an Executor Command and never
   removes the label. A capacity-only pause resumes automatically. Keep unknown
   PR state waiting rather than assuming it is unmerged. Deduplicate per ticket.
3. Add `src/lib/aiur/commands/override_prompt.ex`. Read the current journal state
   each turn; prepend the newest unacknowledged override, including correlation
   for acknowledgement. Do not replay stale startup options. Prevent the normal
   transport from also queuing overrides owned by resume routing. Mark prompt
   delivery only when the provider confirms each turn start. Preserve ordinary
   answer injection. Update `website/docs-app/concepts/commands.md` and the
   existing Stream Deck transport description.

## Verification

New tests in `src/test/aiur/commands/override_resume_test.exs` cover durable fact
round trips, supersession and restart, prompt ordering on cold/resumed/later
turns, cessation after acknowledgement and stale startup data. The same file includes orchestrator
tests that exercise full fleet,
slot release, pressure hold, FIFO/deduplication, explicit labels and same-ticket
resume through a fake runner. Assert active slots never exceed the cap.
Mutation checks remove production changes in an isolated worktree, including
append/prepend and bypassing capacity. Run affected tests, compile, format,
lint, structural and pre-handoff gates. Record real CLI verification as an
Executor-root post-deploy check; agent workspaces cannot run that harness.

## Risks and boundaries

T3/T4/T5 own corrective tickets, replacement and merge races. This scheduler
must hold merged/unknown PRs rather than creating work. Tracker I/O must not
block the orchestrator mailbox. A stale async snapshot cannot authorize a
superseded action: compare current action again before resuming. Restart must
reconstruct waiting work entirely from the Decision journal. Explicit park
approval uses existing Executor Command/attention handling, never direct label
mutation by the scheduler.
