# Persistent Command overrides (#6908)

## Goal and boundary

Accept one override API before or after answer delivery, preserving actor precedence,
version checks and the original Command's audit history. Deliver only the newest
override to an active worker. Other route observations preserve existing
next-session delivery and terminal follow-up until T2–T5 add their routing.
No new UI controls belong here; expose records through the existing presenter.

## Implementation units

1. Add a total pure `Commands.OverrideRoute.choose/3` table and immutable override
   routing metadata on `DecisionRevision`. Persist metadata in the same journal
   event as its answer so a restart cannot split the answer from its record.
   Project queued/delivered/implemented/superseded records onto `Decision`.
2. Serialize override arbitration in `DecisionStore`, reusing supersede when
   replaceable and correlated revisions otherwise. Route through the existing
   delivery target port; never spawn a worker or consume capacity in this ticket.
   Preserve existing scheduling and next-session delivery for every route; keep
   the stale/superseded action fence.
3. Add `Answering.override/3` and connect human answer replacement/correction
   surfaces without changing their presentation. Preserve legacy supersede callers.
4. Project delivery and worker acknowledgement as implementation evidence; observe
   ticket branch pushes and confirm a changed head on the ticket PR before recording
   push evidence. Expose `overrides` in the presenter and document its meaning.

## Validation contract

- New route-table tests cover merged/open/unknown PRs, active/resumable/unrecoverable
  workers and available/full capacity.
- New store tests cover post-delivery acceptance, original/prior action links,
  journal replay, supersession, delivery and acknowledgement/push evidence.
- New facade tests cover stale version and precedence as well as acceptance.
- Existing revision, delivery and affected surface tests remain green.
- Missing event Exchange does not prevent store startup or periodic reconciliation.
- Absent and paused workers receive the newest override once on session start;
  merged/terminal work retains its Executor follow-up.
- Mutation checks run from a separate worktree with only intended production
  reversions. Run compile, format, affected tests, lint and structural/pre-PR gates.
- Post-deploy CLI/TUI smoke requires an Executor checkout and will be recorded
  explicitly in the PR as unrun here.

## Risks and decisions

Routing reads are observations, not claims of certainty: unknown PR state stays
explicit and chooses the unmerged path. Keep Tracker calls out of the serialized
store and resolve context through the delivery port. The journal sequence orders
repeated overrides; stale queued delivery is already fenced by active action ID.
Do not mark implemented on queue acceptance or transport consumption: require a
worker acknowledgement or a verified PR head change after confirmed delivery.
