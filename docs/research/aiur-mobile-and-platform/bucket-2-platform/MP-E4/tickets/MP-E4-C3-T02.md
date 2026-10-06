---
ticket_id: MP-E4-C3-T02
feature_id: MP-E4
chunk_id: MP-E4-C3
bucket: 2-platform
title: "Anchor resolver process: live bus subscription, exact and observed anchors, persisted anchors.jsonl"
status: blocked
blocked_by: [DESIGN-E4, MP-E4-C3-T01, MP-E4-C1-T03, MP-E4-C2-T01]
prior_units: [U3, U6]
prior_boundaries: [BUS, PRJ]
prior_features: [MP-R2 (Exchange stays; export journal R2-C6 enables downtime backfill later)]
prior_findings: [events-and-replay contract §6 (live class); contract conversations-transcripts-anchors §10]
size_owner: n/a (new module; one child line in src/lib/aiur.ex)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-E4-C3-T02 — Anchor resolver

## Identity and outcome

- Bucket 2 · MP-E4 · C3 · T02.
- **User value:** progress updates, Commands, CI, review comments, pushes and
  merges become durable jump points in the conversation where they happened.
- **Deliverable:** `Aiur.Conversation.AnchorResolver` (one process),
  subscribed to the bus before agents start, writing anchors through the
  conversation's journal writer into `anchors.jsonl`, and broadcasting
  `{:anchor_added, …}`. A minimal `Aiur.Conversation.JumpPoints.kind_for/1`
  (topic → kind) that C4-T01 extends.
- **Non-goals:** causal rules (C3-T03); labels and default visibility (C4-T01);
  downtime backfill (needs MP-R2-C6).

## Dependencies and blockers

- DESIGN-E4; MP-E4-C3-T01 (pure functions); MP-E4-C1-T03 (entries carry
  `refs.tool_call_id`); MP-E4-C2-T01 (window reads).
- Concurrent with: C3-T03, C5-T01.

## Verified starting point

- Bus: `Aiur.Events.Exchange.subscribe/2` with AMQP patterns (`*` one
  segment, `#` zero or more; `events/topic.ex:1-40`), delivering
  `{:event, map}` with an always-present `ticket_observation`
  (events contract §4.1; `publisher.ex:298-304`). Exchange is a child at
  `src/lib/aiur.ex:359`; the Orchestrator starts later at `aiur.ex:442`, under
  `:rest_for_one` (`aiur.ex:85-118`).
- GitHub/CI/push events are `live` class; IssueLog markers are per launch and
  only for joinable events with a registered writer (`issue_log.ex:545-560,573-581`).
  So the resolver must be a live subscriber; it cannot rebuild from IssueLog.
- Topics: agent events `ticket.<id>.agent.*`; `ticket.<id>.agent.decision.requested`
  (`decision_store.ex:4604`); `ticket.<id>.pr.opened|merged`
  (`events/github_firehose.ex:419-422`); `ticket.<id>.branch.push` with
  `%{ref, sha}` (`events/ls_remote_ticker.ex:168-183`); `ci.passed|failed`,
  `pr.review_comment`, `issue.commented` (labels in `agent_event_feed.ex:52-72`);
  `executor.*` (Executor journal, `executor_events.ex`).
- Tool call id on agent events: `ticket_observation.provenance.source_event_id`
  (`tool_executor.ex:875-882`). Measured 2026-10-06: 1,851 of 2,164 completed
  publications in 48 launches had a transcript tool entry with the same id in
  the same launch (contract §15).

## Chosen design

PROPOSED `src/lib/aiur/conversation/anchor_resolver.ex`,
`src/lib/aiur/conversation/jump_points.ex` (kind only); child added in
`src/lib/aiur.ex` immediately after `Aiur.Events.Exchange` (`:359`) so it is
bound before any producer runs; T02's `Journal` gains `{:anchor, map}` cast →
`Store.append_anchor_line/2` → broadcast `{:anchor_added, conversation_id,
anchor}` (single writer per conversation, anchors included).

**Subscriptions:** `ticket.*.agent.#`, `ticket.*.pr.#`, `ticket.*.ci.#`,
`ticket.*.branch.push`, `ticket.*.issue.commented`, `executor.#`.

**Per event:**

1. `kind = JumpPoints.kind_for(topic)`; `nil` → ignore (counted).
2. Subject: worker `Ref` from `ticket_observation.tracker_identity` when
   joinable; `executor.*` → `Ref.executor()` if an Executor conversation
   exists (MP-E3), else ignore.
3. `event` map: `event_id` (`ticket_observation.event_id`), `topic`, `kind`,
   `observed_at`, `occurred_at`, `source_tool_call_id`
   (`provenance.source_event_id`), `decision_tool_call_id` (for
   `decision.requested`, from payload `source.event_id` when present),
   `subject_ref` (`head_sha` = payload `sha`; `pr_number` = payload
   `pr["number"]`; `decision_id`).
4. Read the tail window (`History.list_entries(ref, tail: true, limit: 200, principal: :internal)`
   plus `list_sessions/1`).
5. Try `Anchors.exact/2`. If found → append it. If the event has a tool
   call id but no entry yet (the tool result is journaled *after* the tool
   publishes), append the `observed` anchor now and park a **pending exact**
   `{conversation_id, tool_call_id, event}` for 120 s; the resolver
   subscribes to `"conversation:" <> id` and, on `{:entries_appended, …}`
   containing that `refs.tool_call_id`, appends the `exact` anchor. Expiry
   leaves the observed anchor (counted as `exact_expired`).
6. Otherwise append `Anchors.position/3` (`observed` or `unanchored`).

**Restart:** pending exacts are in memory; after a resolver restart the
observed anchors remain (honest, weaker). No IssueLog replay.

**Downtime backfill:** out of scope until MP-R2-C6's export journal exists; the
resolver records its last seen `event_id` per instance in
`<conversation_state_dir>/resolver.json` so the later backfill ticket has a
starting cursor.

**Decision index (Phase D, CR-N6-4):** the resolver also keeps a small
`decision_id → strongest anchor` index (updated when it writes a Command anchor),
which backs `History.anchor_for_decision/1` (conversations contract §7). MP-N6-C1-T01
reads it; without it the device view's `anchor` is `null`.

## Implementation steps

1. `JumpPoints.kind_for/1` covering the contract §10 catalogue topics.
2. Resolver GenServer: `init` subscribes all patterns synchronously (before
   returning, so the `:rest_for_one` order guarantees binding before the
   Orchestrator); `handle_info({:event, ev})`; pending-exact map with timers;
   dynamic `Phoenix.PubSub.subscribe/2` per conversation with pending items,
   unsubscribed when none remain.
3. Journal `{:anchor, map}` cast and broadcast.
4. `resolver.json` cursor write (temp + rename) at most every 5 s.

## Non-happy paths

- **Unjoinable event** (no tracker identity) → ignored and counted; it has no
  conversation.
- **Duplicate delivery** (emit and consumed twins, or webhook + firehose for one
  merge): same `event_id` + kind + precision → same `anchor_id` → the writer
  drops it (dedup on `anchor_id` in the writer's anchor set).
- **Resolver crash:** a bare child in the top-level `:rest_for_one` list would
  restart everything after it, including the Orchestrator. So the resolver
  runs under its own `Aiur.Conversation.ResolverSupervisor` (`:one_for_one`),
  and that supervisor is the child placed right after the Exchange. A resolver
  crash restarts only the resolver (it re-subscribes in `init`); only
  exhausting that supervisor's restart intensity cascades, as for any child.
- **Journal writer down for a conversation:** the anchor cast starts it (T02
  facade); a failed append is retried by the writer's gap logic.
- **High event rate:** the window read is a file read per event; cap at 20
  window reads/s with a token bucket; above it, events queue in the mailbox
  (bounded by the rate of bus events; observed live rate is far lower).

## Compatibility and rollout

- New child + supervisor. No config. Rollback: remove the child; existing
  `anchors.jsonl` stay readable.
- When MP-R2's catalog (R2-C5) lands, the subscription patterns are checked
  against it in a test (every catalogue kind has a registered topic).

## Verification

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" mise exec -- mix test \
  test/aiur/conversation/anchor_resolver_test.exs test/aiur/conversation/jump_points_test.exs
```

| Test | Expected | Fails without |
| --- | --- | --- |
| "progress event with tool call id, entry already present → exact" | one exact anchor `at` the tool entry | `exact/2` call |
| "progress event before its tool entry → observed now, exact after the entry arrives" | two lines: observed then exact | pending-exact path |
| "pending exact expires after 120 s → observed only" (fake clock) | one observed line, `exact_expired` counter 1 | expiry |
| "pr.merged by another actor → observed after last entry" | `placement: after`, `precision: observed` | `position/3` call |
| "event before first session → unanchored" | `pos: nil` | — (covered in C3-T01; here asserts it is persisted, not dropped) |
| "same event delivered twice → one line" | one anchor | writer `anchor_id` dedup |
| "resolver subscribed before Orchestrator starts" (application child order test) | resolver index < Orchestrator index | child placement |
| "resolver crash does not restart the Orchestrator" | Orchestrator pid unchanged | the isolating supervisor |
| "unjoinable event ignored" | no file, counter 1 | identity guard |

Manual (after C5-T03): run one ticket under `aiurdev --test` (AGENTS.md manual
recipe), let the agent emit a progress event and open a PR; check
`anchors.jsonl` holds an `exact` progress anchor and a `pr_opened` anchor, then
see both as jump points in the view.

## Completion and handoff

- [ ] Tests green; `make ci` green on the head SHA.
- [ ] PR body re-measures the exact-match rate on the live fleet with the
      contract §15 method and states it with date and population.
- Dependents: MP-E4-C3-T03, MP-E4-C4-T01, MP-E4-C5-T03, MP-E3 (Executor anchors).
- Docs: none here (C8-T02).
